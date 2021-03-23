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

    def report
      @queue.wait_until_published(@queue_wait_timeout)

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

      flaky_jobs = @queue.flaky_jobs.map { |job| @queue.rerun_command(job) }

      puts summary(@queue.example_failures, @queue.non_example_errors,
        flaky_jobs, humanize_duration(tests_duration))

      flaky_jobs_to_sentry(flaky_jobs, tests_duration)

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

      failures.each do |_job, msg|
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

      errors.each { |_job, msg| summary << msg }

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
        flaky_jobs.each do |j|
          summary << RSpec::Core::Formatters::ConsoleCodes.wrap(
            "#{j}\n",
            RSpec.configuration.pending_color
          )
        end
      end

      summary
    end

    def failure_formatted(rspec_output)
      rspec_output.split("\n")[0..-2].join("\n")
    end

    def humanize_duration(seconds)
      Time.at(seconds).utc.strftime("%H:%M:%S")
    end

    def flaky_jobs_to_sentry(jobs, build_duration)
      return if jobs.empty?

      jobs.each do |job|
        filename = job[/spec\/.+/].split(':')[0]

        extra = {
          build: @build_id,
          build_timeout: @timeout,
          queue: @queue.inspect,
          object: inspect,
          pid: Process.pid,
          rerun_command: job,
          build_duration: build_duration
        }

        tags = {
          flaky: true,
          spec_file: filename
        }

        Raven.capture_message(
          "Flaky test in #{filename}",
          level: "warning",
          extra: extra,
          tags: tags
        )
      end
    end
  end
end
