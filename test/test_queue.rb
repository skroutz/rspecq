require "test_helpers"

class TestQueue < RSpecQTest
  def test_flaky_jobs
    build_id = rand_id

    pid, queue = start_worker("flaky_job_detection", build_id: build_id)
    Process.wait(pid)

    assert_queue_well_formed(queue)
    refute queue.build_successful?

    assert_equal ["./spec/flaky_spec.rb[1:1]", "./spec/flaky_spec.rb[1:3]"],
      queue.flaky_jobs.sort

    assert_processed_jobs(
      ["./spec/passing_spec.rb",
       "./spec/flaky_spec.rb",
       "./spec/flaky_spec.rb[1:1]",
       "./spec/flaky_spec.rb[1:3]",
       "./spec/legit_failure_spec.rb",
       "./spec/legit_failure_spec.rb[1:3]"], queue
    )

    assert_equal 3, queue.flaky_failures.size # legit failure + 2 flakes

    assert_equal [
      "./spec/flaky_spec.rb[1:1]",
      "./spec/flaky_spec.rb[1:3]",
      "./spec/legit_failure_spec.rb[1:3]"
      ],
      queue.flaky_failures.keys.sort

    assert_failures(["./spec/legit_failure_spec.rb[1:3]"], queue)
  end

  def test_push_jobs_returns_jobs_size
    queue = RSpecQ::Queue.new(rand_id, rand_id, REDIS_OPTS)

    assert_equal 2, queue.push_jobs(["job1", "job2"])
  end

  def test_timings_reconstruction
    queue = RSpecQ::Queue.new(rand_id, rand_id, REDIS_OPTS)

    queue.record_build_timing("foo", 42.0)
    queue.record_build_timing("foo[1]", 1.0)

    # Force signature calculation (usually happens in a new test run)
    queue.global_timings(update_sig: true)

    # Update global timings usually happens in the reporter
    assert queue.update_global_timings

    global_timings = queue.global_timings
    assert_equal 42.0, global_timings["foo"], "File timing should not be overriden"
  end

  def test_default_timing
    queue = RSpecQ::Queue.new(rand_id, rand_id, REDIS_OPTS)

    # Record file timings
    queue.record_build_timing("foo", 100.0)
    queue.record_build_timing("bar", 200.0)
    queue.record_build_timing("baz", 300.0)

    # Record individual example timings
    queue.record_build_timing("foo[1]", 1.0)
    queue.record_build_timing("foo[2]", 2.0)
    queue.record_build_timing("bar[1]", 3.0)
    queue.record_build_timing("bar[2]", 4.0)
    queue.record_build_timing("baz[1]", 5.0)
    queue.record_build_timing("baz[2]", 6.0)

    # Force signature calculation (usually happens in a new test run)
    queue.global_timings(update_sig: true)
    assert queue.update_global_timings

    worker = new_worker("not-existing")
    assert_equal 300, worker.default_timing, "Default timing should be the max timing"
  end

  # signature is computed in two distict flow,
  # The master worker flow, when the sig is generated
  # and the reporter flow, when the sig is checked before updating timings
  #
  # We test that those two signatures match
  def test_signature_check
    # 1. Setup global timings
    queue = RSpecQ::Queue.new(rand_id, rand_id, REDIS_OPTS)
    queue.record_build_timing("foo", 100.0)
    queue.record_build_timing("bar", 200.0)
    queue.global_timings(update_sig: true)
    assert queue.update_global_timings

    # Setup a second run that will check the signature
    queue2 = RSpecQ::Queue.new(rand_id, rand_id, REDIS_OPTS)
    queue2.global_timings(update_sig: true)

    # Inject a change in global timings to invalidate the signature
    queue2.redis.zadd(queue2.key_timings, 300.0, "baz")

    refute queue2.update_global_timings
  end
end
