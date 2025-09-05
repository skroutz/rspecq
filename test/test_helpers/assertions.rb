module TestHelpers
  module Assertions
    def assert_queue_well_formed(queue, _msg = nil)
      redis = queue.redis
      heartbeats = redis.zrange(
        queue.send(:key_worker_heartbeats), 0, -1, withscores: true
      )

      refute_nil queue.master
      refute_same "", queue.master
      assert queue.published?
      assert(queue.build_failed_fast? || queue.exhausted?)
      assert_operator heartbeats.size, :>=, 0
      assert(heartbeats.all? { |hb| Time.at(hb.last) <= Time.now })
    end

    def assert_build_not_flakey(queue)
      assert_empty queue.requeued_jobs
    end

    def assert_processed_jobs(exp, queue)
      assert_equal exp.sort, queue.processed_jobs.sort
    end

    def assert_failures(exp, queue)
      assert_equal exp.sort, queue.example_failures.keys.sort
    end
  end
end
