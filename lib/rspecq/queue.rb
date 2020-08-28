require "redis"

module RSpecQ
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
          return job
        end
      end

      return nil
    LUA

    REQUEUE_JOB = <<~LUA.freeze
      local key_queue_unprocessed = KEYS[1]
      local key_requeues = KEYS[2]
      local job = ARGV[1]
      local max_requeues = ARGV[2]

      local requeued_times = redis.call('hget', key_requeues, job)
      if requeued_times and requeued_times >= max_requeues then
        return nil
      end

      redis.call('lpush', key_queue_unprocessed, job)
      redis.call('hincrby', key_requeues, job, 1)

      return true
    LUA

    STATUS_INITIALIZING = "initializing".freeze
    STATUS_READY = "ready".freeze

    attr_reader :redis

    def initialize(build_id, worker_id, redis_host)
      @build_id = build_id
      @worker_id = worker_id
      @redis = Redis.new(host: redis_host, id: worker_id)
    end

    # NOTE: jobs will be processed from head to tail (lpop)
    def publish(jobs)
      @redis.multi do
        @redis.rpush(key_queue_unprocessed, jobs)
        @redis.set(key_queue_status, STATUS_READY)
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
      @redis.multi do
        @redis.hdel(key_queue_running, @worker_id)
        @redis.sadd(key_queue_processed, job)
      end
    end

    # Put job at the head of the queue to be re-processed right after, by
    # another worker. This is a mitigation measure against flaky tests.
    #
    # Returns nil if the job hit the requeue limit and therefore was not
    # requeued and should be considered a failure.
    def requeue_job(job, max_requeues)
      return false if max_requeues.zero?

      @redis.eval(
        REQUEUE_JOB,
        keys: [key_queue_unprocessed, key_requeues],
        argv: [job, max_requeues],
      )
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
      @redis.multi do
        @redis.lpush(key_build_times, Float(duration))
        @redis.ltrim(key_build_times, 0, 99)
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

    def non_example_errors
      @redis.hgetall(key_errors)
    end

    # True if the build is complete, false otherwise
    def exhausted?
      return false if !published?

      @redis.multi do
        @redis.llen(key_queue_unprocessed)
        @redis.hlen(key_queue_running)
      end.inject(:+).zero?
    end

    def published?
      @redis.get(key_queue_status) == STATUS_READY
    end

    def wait_until_published(timeout=30)
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
      raise "Queue is not yet exhausted" if !exhausted?

      requeued = @redis.hkeys(key_requeues)

      return [] if requeued.empty?

      requeued - @redis.hkeys(key_failures)
    end

    # redis: STRING [STATUS_INITIALIZING, STATUS_READY]
    def key_queue_status
      key("queue", "status")
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
