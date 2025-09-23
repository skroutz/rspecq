require "redis"

module RSpecQ
  # Queue is the data store interface (Redis) and is used to manage the work
  # queue for a particular build. All Redis operations happen via Queue.
  #
  # A queue typically contains all the data needed for a particular build to
  # happen. These include (but are not limited to) the following:
  #
  # - the list of jobs (spec files and/or examples) to be executed
  # - the failed examples along with their backtrace
  # - the set of running jobs
  # - previous job timing statistics used to optimally schedule the jobs
  # - the set of executed jobs
  class Queue
    RESERVE_JOB = <<~LUA.freeze
      local queue = KEYS[1]
      local queue_running = KEYS[2]
      local worker_id = ARGV[1]

      local job = redis.call('lpop', queue)
      if job then
        redis.call('hset', queue_running, worker_id, job)
        return job
      else
        return nil
      end
    LUA

    # Scans for dead workers and puts their reserved jobs back to the queue.
    REQUEUE_LOST_JOB = <<~LUA.freeze
      local worker_heartbeats = KEYS[1]
      local queue_running = KEYS[2]
      local queue_unprocessed = KEYS[3]
      local time_now = ARGV[1]
      local timeout = ARGV[2]

      local dead_workers = redis.call('zrangebyscore', worker_heartbeats, 0, time_now - timeout)
      for _, worker in ipairs(dead_workers) do
        local job = redis.call('hget', queue_running, worker)
        if job then
          redis.call('lpush', queue_unprocessed, job)
          redis.call('hdel', queue_running, worker)
          return {job, worker}
        end
      end

      return nil
    LUA

    REQUEUE_JOB = <<~LUA.freeze
      local key_queue_unprocessed = KEYS[1]
      local key_requeues = KEYS[2]
      local key_requeued_job_original_worker = KEYS[3]
      local key_job_location = KEYS[4]
      local job = ARGV[1]
      local max_requeues = ARGV[2]
      local original_worker = ARGV[3]
      local location = ARGV[4]

      local requeued_times = redis.call('hget', key_requeues, job)
      if requeued_times and requeued_times >= max_requeues then
        return nil
      end

      redis.call('lpush', key_queue_unprocessed, job)
      redis.call('hset', key_requeued_job_original_worker, job, original_worker)
      redis.call('hincrby', key_requeues, job, 1)
      redis.call('hset', key_job_location, job, location)

      return true
    LUA

    REMOVE_WORKER = <<~LUA.freeze
      local key_queue_unprocessed = KEYS[1]
      local key_worker_heartbeats = KEYS[2]
      local key_queue_running = KEYS[3]
      local key_workers_withdrawn = KEYS[4]
      local worker = ARGV[1]
      local non_graceful = false

      local job = redis.call('hget', key_queue_running, worker)
      if job then
        redis.call('lpush', key_queue_unprocessed, job)
        redis.call('hdel', key_queue_running, worker)
        redis.call('hincrby', key_workers_withdrawn, worker, 1)

        non_graceful = true
      end

      redis.call('zrem', key_worker_heartbeats, worker)

      return non_graceful
    LUA

    STATUS_INITIALIZING = "initializing".freeze
    STATUS_READY = "ready".freeze

    attr_reader :redis, :build_id, :worker_id

    def initialize(build_id, worker_id, redis_opts)
      @build_id = build_id
      @worker_id = worker_id
      @redis = Redis.new(redis_opts.merge(id: worker_id))
      @script_shas = {}
    end

    # NOTE: jobs will be processed from head to tail (lpop)
    # If publish is false, the queue will not be marked as ready
    # This is handy if we want to push jobs in multiple batches
    # to utilize workers as soon as possible
    def push_jobs(jobs, fail_fast = 0, publish: true)
      time = current_time if publish

      redis.multi do |pipeline|
        pipeline.hset(key_queue_config, "fail_fast", fail_fast)
        pipeline.rpush(key_queue_unprocessed, jobs) if jobs.any?

        pipeline.setnx(key_queue_ready_at, time) if publish
        pipeline.set(key_queue_status, STATUS_READY) if publish
      end

      jobs.size
    end

    def reserve_job
      eval_script(
        RESERVE_JOB,
        keys: [
          key_queue_unprocessed,
          key_queue_running,
        ],
        argv: [@worker_id]
      )
    end

    def requeue_lost_job
      eval_script(
        REQUEUE_LOST_JOB,
        keys: [
          key_worker_heartbeats,
          key_queue_running,
          key_queue_unprocessed
        ],
        argv: [
          current_time,
          WORKER_LIVENESS_SEC
        ]
      )
    end

    # NOTE: The same job might happen to be acknowledged more than once, in
    # the case of requeues.
    def acknowledge_job(job)
      redis.multi do |pipeline|
        pipeline.hdel(key_queue_running, @worker_id)
        pipeline.sadd(key_queue_processed, job)
        pipeline.rpush(key("queue", "jobs_per_worker", @worker_id), job)
      end
    end

    # Put job at the head of the queue to be re-processed right after, by
    # another worker. This is a mitigation measure against flaky tests.
    #
    # Returns nil if the job hit the requeue limit and therefore was not
    # requeued and should be considered a failure.
    def requeue_job(example, max_requeues, original_worker_id)
      return false if max_requeues.zero?

      job = example.id
      location = example.location_rerun_argument

      eval_script(
        REQUEUE_JOB,
        keys: [key_queue_unprocessed, key_requeues, key("requeued_job_original_worker"), key("job_location")],
        argv: [job, max_requeues, original_worker_id, location]
      )
    end

    # Remove worker from the queue, requeuing its reserved job if any.
    def remove_worker(worker)
      eval_script(
        REMOVE_WORKER,
        keys: [
          key_queue_unprocessed,
          key_worker_heartbeats,
          key_queue_running,
          key_workers_withdrawn
        ],
        argv: [worker]
      )
    end

    def save_worker_seed(worker, seed)
      @redis.hset(key("worker_seed"), worker, seed)
    end

    def worker_heartbeats
      @redis.zrange(key_worker_heartbeats, 0, -1, withscores: true).to_h
    end

    def workers_withdrawn
      @redis.hgetall(key_workers_withdrawn)
    end

    def job_location(job)
      @redis.hget(key("job_location"), job)
    end

    def failed_job_worker(job)
      redis.hget(key("requeued_job_original_worker"), job)
    end

    def job_rerun_command(job)
      worker = failed_job_worker(job)
      jobs = redis.lrange(key("queue", "jobs_per_worker", worker), 0, -1)
      # Get the job index or (||) the file index incase we queued the entire file
      # or get all the worker jobs incase something has gone VERY wrong
      job_index = jobs.find_index(job) || jobs.find_index(job.split("[")[0]) || -1
      seed = redis.hget(key("worker_seed"), worker)

      "DISABLE_SPRING=1 DISABLE_BOOTSNAP=1 bin/rspecq --build 1 " \
        "--worker foo --seed #{seed} --max-requeues 0 --fail-fast 1 " \
        "--reproduction #{jobs[0..job_index].join(' ')}"
    end

    def record_example_failure(example_id, message)
      @redis.hset(key_failures, example_id, message)
    end

    # For errors occured outside of examples (e.g. while loading a spec file)
    def record_non_example_error(job, message)
      @redis.hset(key_errors, job, message)
    end

    def record_timing(job, duration)
      @redis.zadd(key_timings, duration, job)
    end

    def record_build_time(duration)
      redis.multi do |pipeline|
        pipeline.lpush(key_build_times, Float(duration))
        pipeline.ltrim(key_build_times, 0, 99)
      end
    end

    def record_worker_heartbeat
      @redis.zadd(key_worker_heartbeats, current_time, @worker_id)
    end

    def increment_example_count(n)
      @redis.incrby(key_example_count, n)
    end

    def example_count
      @redis.get(key_example_count).to_i
    end

    def processed_jobs_count
      @redis.scard(key_queue_processed)
    end

    def processed_jobs
      @redis.smembers(key_queue_processed)
    end

    def requeued_jobs
      @redis.hgetall(key_requeues)
    end

    def become_master
      @redis.setnx(key_queue_status, STATUS_INITIALIZING)
    end

    # ordered by execution time desc (slowest are in the head)
    def timings
      @redis.zrevrange(key_timings, 0, -1, withscores: true).to_h
    end

    def example_failures
      @redis.hgetall(key_failures)
    end

    def non_example_errors
      @redis.hgetall(key_errors)
    end

    # True if the build is complete, false otherwise
    def exhausted?
      return false if !published?

      redis.multi do |pipeline|
        pipeline.llen(key_queue_unprocessed)
        pipeline.hlen(key_queue_running)
      end.inject(:+).zero?
    end

    # Marks the time a master worker is elected. This is used to measure
    # the total build time.
    def mark_elected_master_at
      @redis.set(key_elected_master_at, current_time)
    end

    # Marks the build as finished by setting the finished_at timestamp.
    #
    # Only the first worker to call this method will succeed, subsequent
    # calls will not overwrite the timestamp.
    def try_mark_finished
      @redis.setnx(key_queue_finished_at, current_time)
    end

    # Returns two timings in seconds:
    # - The seconds that the queue took to complete from the time a master
    #   worker was elected.
    # - The seconds that the queue took to complete from the time the queue
    #   was marked ready (i.e. all jobs where published).
    def took_times_secs
      elected_master_at = @redis.get(key_elected_master_at)
      ready_at = @redis.get(key_queue_ready_at)
      finished_at = @redis.get(key_queue_finished_at)

      return nil if elected_master_at.nil? || ready_at.nil? || finished_at.nil?

      [
        finished_at.to_i - elected_master_at.to_i,
        finished_at.to_i - ready_at.to_i
      ]
    end

    def published?
      @redis.get(key_queue_status) == STATUS_READY
    end

    def wait_until_published(timeout = 30)
      (timeout * 10).times do
        return if published?

        sleep 0.1
      end

      raise "Queue not yet published after #{timeout} seconds"
    end

    def build_successful?
      exhausted? && example_failures.empty? && non_example_errors.empty?
    end

    # The remaining jobs to be processed. Jobs at the head of the list will
    # be procesed first.
    def unprocessed_jobs
      @redis.lrange(key_queue_unprocessed, 0, -1)
    end

    # Returns the jobs considered flaky (i.e. initially failed but passed
    # after being retried). Must be called after the build is complete,
    # otherwise an exception will be raised.
    def flaky_jobs
      if !exhausted? && !build_failed_fast?
        raise "Queue is not yet exhausted"
      end

      requeued = @redis.hkeys(key_requeues)

      return [] if requeued.empty?

      requeued - @redis.hkeys(key_failures)
    end

    # Returns the number of failures that will trigger the build to fail-fast.
    # Returns 0 if this feature is disabled and nil if the Queue is not yet
    # published
    def fail_fast
      return nil unless published?

      @fail_fast ||= Integer(@redis.hget(key_queue_config, "fail_fast"))
    end

    # Returns true if the number of failed tests, has surpassed the threshold
    # to render the run unsuccessful and the build should be terminated.
    def build_failed_fast?
      if fail_fast.nil? || fail_fast.zero?
        return false
      end

      redis.multi do |pipeline|
        pipeline.hlen(key_failures)
        pipeline.hlen(key_errors)
      end.inject(:+) >= fail_fast
    end

    # redis: STRING [STATUS_INITIALIZING, STATUS_READY]
    def key_queue_status
      key("queue", "status")
    end

    # redis:  HASH<config_key => config_value>
    def key_queue_config
      key("queue", "config")
    end

    # redis: LIST<job>
    def key_queue_unprocessed
      key("queue", "unprocessed")
    end

    # redis: HASH<worker_id => job>
    def key_queue_running
      key("queue", "running")
    end

    # redis: SET<job>
    def key_queue_processed
      key("queue", "processed")
    end

    # Contains the timestamp of when a master worker was elected
    #
    # redis: STRING<timestamp>
    def key_elected_master_at
      key("queue", "elected_master_at")
    end

    # Contains the timestamp of when the build started
    #
    # redis: STRING<timestamp>
    def key_queue_ready_at
      key("queue", "ready_at")
    end

    # Contains the timestamp of when the build finished.
    #
    # redis: STRING<timestamp>
    def key_queue_finished_at
      key("queue", "finished_at")
    end

    # Contains regular RSpec example failures.
    #
    # redis: HASH<example_id => error message>
    def key_failures
      key("example_failures")
    end

    # Contains errors raised outside of RSpec examples
    # (e.g. a syntax error in spec_helper.rb).
    #
    # redis: HASH<job => error message>
    def key_errors
      key("errors")
    end

    # As a mitigation mechanism for flaky tests, we requeue example failures
    # to be retried by another worker, up to a certain number of times.
    #
    # redis: HASH<job => times_retried>
    def key_requeues
      key("requeues")
    end

    # The total number of examples, those that were requeued.
    #
    # redis: STRING<integer>
    def key_example_count
      key("example_count")
    end

    # The total number of times a worker was removed while having a reserved job.
    # This might happen if the worker is terminated in a non-graceful way.
    def key_workers_withdrawn
      key("workers_withdrawn")
    end

    # redis: ZSET<worker_id => timestamp>
    #
    # Timestamp of the last example processed by each worker.
    def key_worker_heartbeats
      key("worker_heartbeats")
    end

    # redis: ZSET<job => duration>
    #
    # NOTE: This key is not scoped to a build (i.e. shared among all builds),
    # so be careful to only publish timings from a single branch (e.g. master).
    # Otherwise, timings won't be accurate.
    def key_timings
      "timings"
    end

    # redis: LIST<duration>
    #
    # Last build is at the head of the list.
    def key_build_times
      "build_times"
    end

    private

    def eval_script(script, keys: [], argv: [])
      sha = @script_shas[script] ||= @redis.script(:load, script)
      @redis.evalsha(sha, keys: keys, argv: argv)
    rescue Redis::CommandError => e
      raise unless e.message.include?("NOSCRIPT")

      # The script was evicted from Redis. Let's reload it.
      @script_shas[script] = nil
      retry
    end

    def key(*keys)
      [@build_id, keys].join(":")
    end

    # We don't use any Ruby `Time` methods because specs that use timecop in
    # before(:all) hooks will mess up our times.
    def current_time
      @redis.time[0]
    end
  end
end
