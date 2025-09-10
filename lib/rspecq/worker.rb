require "json"
require "pathname"
require "pp"
require "open3"

module RSpecQ
  # A Worker, given a build ID, continuously consumes tests off the
  # corresponding and executes them, until the queue is empty.
  # It is also responsible for populating the initial queue.
  #
  # Essentially, a worker is an RSpec runner that prints the results of the
  # tests it executes to standard output.
  #
  # The typical use case is to spawn many workers for a given build, thereby
  # parallelizing the work and achieving faster build times.
  #
  # Workers are readers+writers of the queue.
  class Worker
    HEARTBEAT_FREQUENCY = WORKER_LIVENESS_SEC / 6

    # The root path or individual spec files to execute.
    #
    # Defaults to "spec" (similar to RSpec)
    attr_accessor :files_or_dirs_to_run

    # If set, spec files that are known to take more than this value to finish,
    # will be split and scheduled on a per-example basis.
    #
    # Defaults to 999999
    attr_accessor :file_split_threshold

    # If set, worker will *only* try to emit up to a certain number of jobs
    # as soon as possible to increase job fairness.
    #
    # Defaults to nil (disabled)
    attr_accessor :early_push_max_jobs

    # Retry failed examples up to N times (with N being the supplied value)
    # before considering them legit failures
    #
    # Defaults to 3
    attr_accessor :max_requeues

    # Stop the execution after N failed tests. Do not stop at any point when
    # set to 0.
    #
    # Defaults to 0
    attr_accessor :fail_fast

    # Time to wait for a queue to be published.
    #
    # Defaults to 30
    attr_accessor :queue_wait_timeout

    # The RSpec seed
    attr_accessor :seed

    # Rspec tags
    attr_accessor :tags

    # Reproduction flag. If true, worker will publish files in the exact order
    # given in the command.
    attr_accessor :reproduction

    attr_reader :queue, :build_id, :worker_id, :redis_opts

    def initialize(build_id:, worker_id:, redis_opts:, shutdown_pipe: nil)
      @build_id = build_id
      @worker_id = worker_id
      @redis_opts = redis_opts
      @queue = Queue.new(build_id, worker_id, redis_opts)
      @fail_fast = 0
      @files_or_dirs_to_run = "spec"
      @file_split_threshold = 999_999
      @heartbeat_updated_at = nil
      @max_requeues = 3
      @queue_wait_timeout = 30
      @seed = srand && (srand % 0xFFFF)
      @tags = []
      @reproduction = false
      @shutdown_pipe = shutdown_pipe

      RSpec::Core::Formatters.register(Formatters::JobTimingRecorder, :dump_summary)
      RSpec::Core::Formatters.register(Formatters::ExampleCountRecorder, :dump_summary)
      RSpec::Core::Formatters.register(Formatters::FailureRecorder, :example_failed, :message)
      RSpec::Core::Formatters.register(Formatters::WorkerHeartbeatRecorder, :example_finished)
    end

    def shutdown?
      @shutdown_pipe&.ready?
    end

    # Do not exit when finished, so that k8s pod does not restart the container
    # In our setup the pod will be shutdown by other means (reporter exiting || timeout)
    def exit_when_finished?
      ENV["RSPECQ_EXIT_WHEN_FINISHED"] != "0"
    end

    def work
      puts "Working for build #{@build_id} (worker=#{@worker_id})"

      q_size = try_publish_queue!(queue)
      puts "Published queue (size=#{q_size})" if q_size

      queue.save_worker_seed(@worker_id, seed)

      loop do
        # we have to bootstrap this so that it can be used in the first call
        # to `requeue_lost_job` inside the work loop
        update_heartbeat

        return if shutdown?

        if queue.build_failed_fast?
          return if exit_when_finished?

          sleep 1
        end

        lost = queue.requeue_lost_job
        puts "Requeued lost job: #{lost}" if lost

        # TODO: can we make `reserve_job` also act like exhausted? and get
        # rid of `exhausted?` (i.e. return false if no jobs remain)
        job = queue.reserve_job

        # build is finished
        if job.nil? && queue.exhausted?
          queue.try_mark_finished

          return if exit_when_finished?

          sleep 1
        end

        if job.nil?
          # backoff if no job is available
          sleep 1
          next
        end

        puts
        puts "Executing #{job}"

        reset_rspec_state!

        # reconfigure rspec
        RSpec.configuration.detail_color = :magenta
        RSpec.configuration.seed = seed
        RSpec.configuration.backtrace_formatter.filter_gem("rspecq")
        RSpec.configuration.add_formatter(Formatters::FailureRecorder.new(queue, job, max_requeues, @worker_id))
        RSpec.configuration.add_formatter(Formatters::ExampleCountRecorder.new(queue))
        RSpec.configuration.add_formatter(Formatters::WorkerHeartbeatRecorder.new(self))
        RSpec.configuration.add_formatter(Formatters::JobTimingRecorder.new(queue, job))

        options = ["--format", "progress", job]
        tags.each { |tag| options.push("--tag", tag) }
        opts = RSpec::Core::ConfigurationOptions.new(options)
        _result = RSpec::Core::Runner.new(opts).run($stderr, $stdout)

        queue.acknowledge_job(job)
      end
    end

    # Update the worker heartbeat if necessary
    def update_heartbeat
      if @heartbeat_updated_at.nil? || elapsed(@heartbeat_updated_at) >= HEARTBEAT_FREQUENCY
        queue.record_worker_heartbeat
        @heartbeat_updated_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    def global_timings
      @global_timings ||= queue.global_timings
    end

    def try_publish_queue!(queue)
      return if !queue.become_master

      queue.mark_elected_master_at

      if reproduction
        q_size = queue.push_jobs(files_or_dirs_to_run, fail_fast)
        log_event(
          "Reproduction mode. Published queue as given (size=#{q_size})",
          "info"
        )
        return q_size
      end

      puts "I am the master worker (worker_id=#{@worker_id}), publishing the queue..."

      RSpec.configuration.files_or_directories_to_run = files_or_dirs_to_run
      files_to_run = RSpec.configuration.files_to_run.map { |j| relative_path(j) }

      if global_timings.empty?
        q_size = queue.push_jobs(files_to_run.shuffle, fail_fast)
        log_event(
          "No global timings found! Published queue in random order (size=#{q_size})",
          "warning"
        )
        return q_size
      end

      # prepare jobs to run
      slow_files = []

      if file_split_threshold
        slow_files = global_timings.take_while do |_job, duration|
          duration >= file_split_threshold
        end.map(&:first) & files_to_run
      end

      if slow_files.empty?
        return queue.push_jobs(order_jobs_by_timings(files_to_run), fail_fast)
      end

      jobs = order_jobs_by_timings(files_to_run - slow_files)
      pending = []

      # Push non-slow files first to make sure that workers can start working
      if early_push_max_jobs # push jobs up to the threshold
        rest = jobs

        jobs = rest.shift(early_push_max_jobs)
        pending = rest
      end

      queue.push_jobs(jobs, fail_fast, publish: false)

      # Populate splitted slow files
      pending += files_to_example_ids(slow_files)

      queue.push_jobs(order_jobs_by_timings(pending), fail_fast)
    end

    private

    def order_jobs_by_timings(jobs)
      timings = global_timings

      default_timing = timings.values[timings.values.size / 2]

      jobs = jobs.each_with_object({}) do |j, h|
        puts "Untimed job: #{j}" if timings[j].nil?

        # HEURISTIC: put jobs without previous timings (e.g. a newly added
        # spec file) in the middle of the queue
        h[j] = timings[j] || default_timing
      end

      # sort jobs based on their timings (slowest to be processed first)
      jobs.sort_by { |_j, t| -t }.map(&:first)
    end

    def reset_rspec_state!
      RSpec.clear_examples

      # see https://github.com/rspec/rspec-core/pull/2723
      if Gem::Version.new(RSpec::Core::Version::STRING) <= Gem::Version.new("3.9.1")
        RSpec.world.instance_variable_set(
          :@example_group_counts_by_spec_file, Hash.new(0)
        )
      end

      # RSpec.clear_examples does not reset those, which causes issues when
      # a non-example error occurs (subsequent jobs are not executed)
      # TODO: upstream
      RSpec.world.non_example_failure = false

      # we don't want an error that occured outside of the examples (which
      # would set this to `true`) to stop the worker
      RSpec.world.wants_to_quit = false
    end

    # NOTE: RSpec has to load the files before we can split them as individual
    # examples. In case a file to be splitted fails to be loaded
    # (e.g. contains a syntax error), we return the files unchanged, thereby
    # falling back to scheduling them as whole files. Their errors will be
    # reported in the normal flow when they're eventually picked up by a worker.
    def files_to_example_ids(files)
      cmd = "DISABLE_SPRING=1 bundle exec rspec --dry-run --format json #{files.join(' ')}"
      out, err, cmd_result = Open3.capture3(cmd)

      if !cmd_result.success?
        rspec_output = begin
          JSON.parse(out)
        rescue JSON::ParserError
          out
        end

        log_event(
          "Failed to split slow files, falling back to regular scheduling",
          "error",
          rspec_stdout: rspec_output,
          rspec_stderr: err,
          cmd_result: cmd_result.inspect
        )

        pp rspec_output

        return files
      end

      JSON.parse(out)["examples"].map { |e| e["id"] }
    rescue JSON::ParserError => e
      log_event(
        "Failed to parse rspec json output, falling back to regular scheduling",
        "error",
        error: e.message,
        rspec_stdout: out,
        cmd_result: cmd_result.inspect
      )

      files
    end

    def relative_path(job)
      @cwd ||= Pathname.new(Dir.pwd)
      "./#{Pathname.new(job).relative_path_from(@cwd)}"
    end

    def elapsed(since)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - since
    end

    # Prints msg to standard output and emits an event to Sentry, if the
    # SENTRY_DSN environment variable is set.
    def log_event(msg, level, additional = {})
      warn msg

      Raven.capture_message(msg, level: level, extra: {
        build: @build_id,
        worker: @worker_id,
        queue: queue.inspect,
        files_or_dirs_to_run: files_or_dirs_to_run,
        file_split_threshold: file_split_threshold,
        heartbeat_updated_at: @heartbeat_updated_at,
        object: inspect,
        pid: Process.pid
      }.merge(additional))
    end
  end
end
