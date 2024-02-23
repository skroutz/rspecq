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
    # If true, job timings will be populated in the global Redis timings key
    #
    # Defaults to false
    attr_accessor :update_timings

    def initialize(build_id:, timeout:, redis_opts:,
                   queue_wait_timeout: 30,
                   update_timings: false,
                   timings_key: nil)
      @build_id = build_id
      @timeout = timeout
      @queue = Queue.new(build_id, "reporter", redis_opts)
      @queue_wait_timeout = queue_wait_timeout
      @update_timings = update_timings
      @timings_key = timings_key

      # We want feedback to be immediattely printed to CI users, so
      # we disable buffering.
      $stdout.sync = true
    end

    def report
      @queue.wait_until_published(@queue_wait_timeout)

      finished = false

      reported_failures = {}
      failure_heading_printed = false

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

      raise "Build not finished after #{@timeout} seconds" if !finished

      build_duration = test_durations&.first
      @queue.record_build_time(build_duration) if build_duration

      if update_timings && @queue.build_successful?
        if @timings_key
          puts "Updating job timings @ #{@timings_key}"
          @queue.update_global_timings(@timings_key)
        else
          puts "Updating global job timings"
          @queue.update_global_timings
        end
      end

      flaky_jobs = @queue.flaky_jobs

      puts summary(@queue.example_failures, @queue.non_example_errors,
        flaky_jobs)

      flaky_jobs_to_sentry(flaky_jobs, build_duration, @queue.flaky_failures)

      exit 1 if !@queue.build_successful?
    end

    private

    def test_durations
      @test_durations ||= @queue.took_times_secs
    end

    # We try to keep this output consistent with RSpec's original output
    def summary(failures, errors, flaky_jobs)
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

      requeues = @queue.requeued_jobs.values.sum

      summary << "\n"
      summary << "Total results:\n"
      summary << "  #{@queue.example_count} examples "     \
                 "(#{@queue.processed_jobs_count} jobs), " \
                 "#{failures.count} failures, "            \
                 "#{errors.count} errors, "                \
                 "#{requeues} requeues"
      summary << ", #{flaky_jobs.count} flaky" if flaky_jobs.any?
      summary << ", #{@queue.workers_withdrawn.count} withdrawals" if @queue.workers_withdrawn.any?
      summary << ", #{@queue.lost_jobs_count} lost jobs (unique)" if @queue.lost_jobs_count.positive?
      summary << "\n\n\n"

      from_elected_master, from_queue_ready = test_durations
      if from_elected_master
        summary << "Spec time (from elected master)\t: #{humanize_duration(from_elected_master)}\n"
      end

      if from_queue_ready
        summary << "Spec time (from queue ready)\t: #{humanize_duration(from_queue_ready)}\n"
      end

      summary << "Worker total execution time\t: #{humanize_duration(@queue.total_execution_time_ms / 1000)}\n"

      if @queue.workers_withdrawn.any?
        summary << "\n"
        summary << "Workers withdrawn (count=#{@queue.workers_withdrawn.count}):\n"
        @queue.workers_withdrawn.each do |worker, count|
          summary << "  Worker #{worker} withdrawn #{count} times\n"
        end
      end

      if !flaky_jobs.empty?
        summary << "\n\n"
        summary << "::group::Flaky jobs detected (count=#{flaky_jobs.count}):\n"
        flaky_jobs.each do |j|
          job_timing = if (jt = @queue.job_build_timing(j))
                         humanize_duration(jt.to_i)
                       else
                         "---"
                       end
          summary << RSpec::Core::Formatters::ConsoleCodes.wrap(
            "#{@queue.job_location(j)} @ #{@queue.failed_job_worker(j)} timing=#{job_timing}\n",
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

    def humanize_duration(secs)
      min, sec = secs.divmod(60)

      format("%<min>d:%<sec>02d", min: min, sec: sec)
    end

    def flaky_jobs_to_sentry(jobs, build_duration, failures)
      return if jobs.empty?

      jobs.each do |job|
        filename = job.sub(/\[.+\]/, "")[%r{spec/.+}].split(":")[0]

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
          spec_file: filename
        }

        Sentry.capture_message(
          "Flaky test in #{filename}",
          level: "warning",
          extra: extra,
          tags: tags
        )
      end
    end
  end
end
