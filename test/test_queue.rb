require "test_helpers"

class TestQueue < RSpecQTest
  def test_flaky_jobs
    build_id = rand_id

    Process.wait(start_worker(build_id: build_id, suite: "flaky_job_detection"))

    queue = RSpecQ::Queue.new(build_id, "foo", REDIS_HOST)

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
       "./spec/legit_failure_spec.rb[1:3]"], queue)

    assert_failures(["./spec/legit_failure_spec.rb[1:3]"], queue)
  end
end
