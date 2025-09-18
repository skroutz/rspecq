require "test_helpers"

class TestConcurrentWorkers < RSpecQTest
  # The 'passing_concurrent' suite contains 5 spec files each containing a
  # single example taking 2". We spawn that many workers so we expect roughly
  # 2 second total execution time. We some more  to account for fork and
  # rspec boot and other setup overheads
  def test_passing_suite
    build_id = rand_id
    pids = []
    job_count = 5

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    job_count.times do
      pid, _q = start_worker("passing_concurrent", build_id: build_id)
      pids << pid
    end

    pids.each { |p| Process.wait(p) }

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    assert_operator elapsed, :<, 5

    queue = RSpecQ::Queue.new(build_id, "foo", REDIS_OPTS)

    assert_queue_well_formed(queue)
    assert queue.build_successful?
    assert_equal job_count, queue.example_count
    assert_equal job_count, queue.redis.zcard(queue.key_worker_heartbeats)
  end

  def test_flakey_suite
    skip
  end

  def test_failing_suite_with_requeues
    skip
  end

  def test_passing_suite_with_faulty_worker
    skip
  end
end
