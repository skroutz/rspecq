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

    queue.update_global_timings

    global_timings = queue.global_timings

    assert_equal 42.0, global_timings["foo"], "File timing should not be overriden"
  end
end
