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
      local queue_lost = KEYS[4]
      local time_now = ARGV[1]
      local timeout = ARGV[2]

      local dead_workers = redis.call('zrangebyscore', worker_heartbeats, 0, time_now - timeout)
      for _, worker in ipairs(dead_workers) do
        local job = redis.call('hget', queue_running, worker)
        if job then
          redis.call('lpush', queue_unprocessed, job)
          redis.call('hdel', queue_running, worker)
          redis.call('zincrby', queue_lost, 1, job)
          return job
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
      local worker = ARGV[1]

      local job = redis.call('hget', key_queue_running, worker)
      if job then
        redis.call('lpush', key_queue_unprocessed, job)
      end

      redis.call('zrem', key_worker_heartbeats, worker)
      redis.call('hdel', key_queue_running, worker)

      return true
    LUA

    STATUS_INITIALIZING = "initializing".freeze
    STATUS_READY = "ready".freeze

    attr_reader :redis

    def initialize(build_id, worker_id, redis_opts)
      @build_id = build_id
      @worker_id = worker_id
      @redis = Redis.new(redis_opts.merge(id: worker_id))
    end

    # NOTE: jobs will be processed from head to tail (lpop)
    # Also some state keys are wiped to facilitate re-runs
    # with the same job build prefix.
    def publish(jobs, fail_fast = 0)
      cleanup_keys = [
        key_queue_unprocessed, key_queue_running, key_queue_processed, key_failures,
        key_flaky_failures, key_errors, key_requeues, key_example_count,
        key_worker_heartbeats, key_queue_lost
      ]

      @redis.multi do |transaction|
        cleanup_keys.each do |key|
          transaction.del(key)
        end
        transaction.hset(key_queue_config, "fail_fast", fail_fast)
        transaction.rpush(key_queue_unprocessed, jobs)
        transaction.set(key_queue_status, STATUS_READY)
      end.first
    end

    def reserve_job
      @redis.eval(
        RESERVE_JOB,
        keys: [
          key_queue_unprocessed,
          key_queue_running,
        ],
        argv: [@worker_id]
      )
    end

    def requeue_lost_job
      @redis.eval(
        REQUEUE_LOST_JOB,
        keys: [
          key_worker_heartbeats,
          key_queue_running,
          key_queue_unprocessed,
          key_queue_lost
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
      @redis.multi do |transaction|
        transaction.hdel(key_queue_running, @worker_id)
        transaction.sadd(key_queue_processed, job)
        transaction.rpush(key("queue", "jobs_per_worker", @worker_id), job)
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

      @redis.eval(
        REQUEUE_JOB,
        keys: [key_queue_unprocessed, key_requeues, key("requeued_job_original_worker"), key("job_location")],
        argv: [job, max_requeues, original_worker_id, location]
      )
    end

    def remove_worker(worker)
      @redis.eval(
        REMOVE_WORKER,
        keys: [key_queue_unprocessed, key_worker_heartbeats, key_queue_running],
        argv: [worker]
      )
    end

    def save_worker_seed(worker, seed)
      @redis.hset(key("worker_seed"), worker, seed)
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
      job_index = jobs.find_index(job) || jobs.find_index(job.split('[')[0]) || -1
      seed = redis.hget(key("worker_seed"), worker)

      "DISABLE_SPRING=1 DISABLE_BOOTSNAP=1 bin/rspecq " \
        "--seed #{seed} --max-requeues 0 --fail-fast 1 " \
        "--reproduction #{jobs[0..job_index].join(' ')}"
    end

    def record_example_failure(example_id, message)
      @redis.hset(key_failures, example_id, message)
    end

    def record_flaky_failure(example_id, message)
      @redis.hset(key_flaky_failures, example_id, message)
    end

    # For errors occured outside of examples (e.g. while loading a spec file)
    def record_non_example_error(job, message)
      @redis.hset(key_errors, job, message)
    end

    def record_timing(job, duration)
      @redis.zadd(key_timings, duration, job)
    end

    def record_build_time(duration)
      @redis.multi do |transaction|
        transaction.lpush(key_build_times, Float(duration))
        transaction.ltrim(key_build_times, 0, 99)
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
      Hash[@redis.zrevrange(key_timings, 0, -1, withscores: true)]
    end

    def example_failures
      @redis.hgetall(key_failures)
    end

    def flaky_failures
      @redis.hgetall(key_flaky_failures)
    end

    def non_example_errors
      @redis.hgetall(key_errors)
    end

    # True if the build is complete, false otherwise
    def exhausted?
      return false if !published?

      @redis.multi do |transaction|
        transaction.llen(key_queue_unprocessed)
        transaction.hlen(key_queue_running)
      end.inject(:+).zero?
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

      @redis.multi do |transaction|
        transaction.hlen(key_failures)
        transaction.hlen(key_errors)
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

    # redis: ZSET<job>
    def key_queue_lost
      key("queue", "lost")
    end

    # Contains regular RSpec example failures.
    #
    # redis: HASH<example_id => error message>
    def key_failures
      key("example_failures")
    end

    # Contains flaky RSpec example failures.
    #
    # redis: HASH<example_id => error message>
    def key_flaky_failures
      key("flaky_failures")
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
