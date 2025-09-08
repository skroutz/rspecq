module RSpecQ
  # A Reporter, given a build ID, is responsible for consolidating the results
  # from different workers and printing a complete build summary to the user,
  # along with any failures that might have occured.
  #
  # The failures are printed in real-time as they occur, while the final
  # summary is printed after the queue is empty and no tests are being
  # executed. If the build failed, the status code of the reporter is non-zero.
  #
  # Reporters are readers of the queue.
  class Reporter
    def initialize(build_id:, timeout:, redis_opts:, queue_wait_timeout: 30)
      @build_id = build_id
      @timeout = timeout
      @queue = Queue.new(build_id, "reporter", redis_opts)
      @queue_wait_timeout = queue_wait_timeout

      # We want feedback to be immediattely printed to CI users, so
      # we disable buffering.
      $stdout.sync = true
    end

    def wait_until_published
      master = nil

      puts "Waiting until the queue is published..."
      @queue.wait_until_published(@queue_wait_timeout) do
        # This block is called during checking if the queue is published.
        next if master.nil? || master.empty? # Printing master info only once

        master = @queue.master
        puts "Build master is worker #{master}"
      end

      puts "Queue published by worker #{master}"
    rescue RuntimeError => e
      puts "Error waiting for queue to be published: #{e.message}"
      raise e
    end

    def report
      wait_until_published

      finished = false

      reported_failures = {}
      failure_heading_printed = false

      tests_duration = measure_duration do
        @timeout.times do
          @queue.example_failures.each do |job, rspec_output|
            next if reported_failures[job]

            if !failure_heading_printed
              puts "\nFailures:\n"
              failure_heading_printed = true
            end

            reported_failures[job] = true
            puts failure_formatted(rspec_output)
          end

          unless @queue.exhausted? || @queue.build_failed_fast?
            sleep 1
            next
          end

          finished = true
          break
        end
      end

      raise "Build not finished after #{@timeout} seconds" if !finished

      @queue.record_build_time(tests_duration)

      flaky_jobs = @queue.flaky_jobs

      puts summary(@queue.example_failures, @queue.non_example_errors,
        flaky_jobs, humanize_duration(tests_duration))

      flaky_jobs_to_sentry(tests_duration, @queue.flaky_failures)

      exit 1 if !@queue.build_successful?
    end

    private

    def measure_duration
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(2)
    end

    # We try to keep this output consistent with RSpec's original output
    def summary(failures, errors, flaky_jobs, duration)
      failed_examples_section = "\nFailed examples:\n\n"

      failures.each_value do |msg|
        parts = msg.split("\n")
        failed_examples_section << "  #{parts[-1]}\n"
      end

      summary = ""
      if @queue.build_failed_fast?
        summary << "\n\n"
        summary << "The limit of #{@queue.fail_fast} failures has been reached\n"
        summary << "Aborting..."
        summary << "\n"
      end

      summary << failed_examples_section if !failures.empty?

      errors.each_value { |msg| summary << msg }

      summary << "\n"
      summary << "Total results:\n"
      summary << "  #{@queue.example_count} examples "     \
                 "(#{@queue.processed_jobs_count} jobs), " \
                 "#{failures.count} failures, "            \
                 "#{errors.count} errors"
      summary << "\n\n"
      summary << "Spec execution time: #{duration}"

      if !flaky_jobs.empty?
        summary << "\n\n"
        summary << "Flaky jobs detected (count=#{flaky_jobs.count}):\n"
        summary << "::group::Flaky tests details\n"
        flaky_jobs.each do |j|
          summary << RSpec::Core::Formatters::ConsoleCodes.wrap(
            "#{@queue.job_location(j)} @ #{@queue.failed_job_worker(j)}\n",
            RSpec.configuration.pending_color
          )

          next if ENV["RSPECQ_REPORTER_RERUN_COMMAND_SKIP"]

          summary << "#{@queue.job_rerun_command(j)}\n\n\n"
        end
        summary << "::endgroup::\n"
      end

      summary
    end

    def failure_formatted(rspec_output)
      rspec_output.split("\n")[0..-2].join("\n")
    end

    def humanize_duration(seconds)
      Time.at(seconds).utc.strftime("%H:%M:%S")
    end

    def flaky_jobs_to_sentry(build_duration, failures)
      return if failures.empty?

      failures.each do |job, msg|
        filename = job.sub(/\[.+\]/, "")[%r{spec/.+}].split(":")[0]
        spec_name = msg.split("\n")[1].strip
        # Use this digest in order to make the Sentry event name unique per spec
        sha = Digest::SHA1.hexdigest(filename + spec_name)
        event_message = "#{filename} #{sha}"

        extra = {
          build: @build_id,
          build_timeout: @timeout,
          build_duration: build_duration,
          location: @queue.job_location(job),
          rerun_command: @queue.job_rerun_command(job),
          worker: @queue.failed_job_worker(job),
          output: failures[job]
        }

        tags = {
          flaky: true,
          spec_file: filename,
          spec_sha: sha
        }

        Sentry.capture_message(
          event_message,
          level: "warning",
          extra: extra,
          tags: tags
        )
      end
    end
  end
end
