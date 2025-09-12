require "test_helpers"

class TestEndToEnd < RSpecQTest
  def test_suite_with_legit_failures
    queue = exec_build("failing_suite")

    refute queue.build_successful?
    assert queue.fail_fast.zero?
    refute queue.build_failed_fast?

    assert_empty queue.unprocessed_jobs
    assert_processed_jobs [
      "./spec/fail_1_spec.rb",
      "./spec/fail_1_spec.rb[1:2]",
      "./spec/fail_2_spec.rb",
      "./spec/fail_2_spec.rb[1:2]",
      "./spec/success_spec.rb",
    ], queue

    assert_equal 3 + 3 + 5, queue.example_count

    assert_equal(
      { "./spec/fail_1_spec.rb[1:2]" => 3,
        "./spec/fail_2_spec.rb[1:2]" => 3 },
      queue.requeued_jobs
    )
  end

  def test_passing_suite
    queue = exec_build("passing_suite")

    assert queue.build_successful?
    assert_build_not_flakey(queue)
    assert_equal 1, queue.example_count
    assert_equal ["./spec/foo_spec.rb"], queue.processed_jobs
  end

  def test_flakey_suite
    queue = exec_build("flakey_suite")

    assert queue.build_successful?
    assert_processed_jobs [
      "./spec/foo_spec.rb",
      "./spec/foo_spec.rb[1:1]",
    ], queue

    assert_equal({ "./spec/foo_spec.rb[1:1]" => 2 }, queue.requeued_jobs)
  end

  def test_flakey_suite_without_retries
    queue = exec_build("flakey_suite", "--max-requeues=0")

    refute(queue.build_successful?)
    assert_processed_jobs [
      "./spec/foo_spec.rb",
    ], queue

    assert_empty(queue.requeued_jobs)
  end

  def test_scheduling_by_file_and_custom_spec_path
    queue = exec_build("different_spec_path", "mytests/qwe_spec.rb")

    assert queue.build_successful?
    assert_build_not_flakey(queue)
    assert_equal 2, queue.example_count
    assert_processed_jobs ["./mytests/qwe_spec.rb"], queue
  end

  def test_non_example_error
    queue = exec_build("non_example_error")

    refute queue.build_successful?
    assert_build_not_flakey(queue)
    assert_equal 1, queue.example_count
    assert_processed_jobs ["./spec/foo_spec.rb", "./spec/bar_spec.rb"], queue
    assert_equal ["./spec/foo_spec.rb"], queue.non_example_errors.keys
  end

  def test_build_timings_update
    queue = exec_build("timings")

    assert queue.build_successful?

    assert_equal [
      "./spec/very_fast_spec.rb",
      "./spec/fast_spec.rb",
      "./spec/medium_spec.rb",
      "./spec/slow_spec.rb",
      "./spec/very_slow_spec.rb",
    ], queue.build_timings.sort_by { |_, v| v }.map(&:first)
  end

  def test_global_timings_update
    queue = exec_build("timings")
    exec_reporter("--update-timings", build_id: queue.build_id)

    assert queue.build_successful?

    assert_equal [
      "./spec/very_fast_spec.rb",
      "./spec/fast_spec.rb",
      "./spec/medium_spec.rb",
      "./spec/slow_spec.rb",
      "./spec/very_slow_spec.rb",
    ], queue.global_timings.sort_by { |_, v| v }.map(&:first)
  end

  def test_timings_no_update
    queue = exec_build("timings")

    assert queue.build_successful?
    assert_empty queue.global_timings
  end

  def test_spec_file_splitting
    queue = exec_build("spec_file_splitting")
    assert queue.build_successful?

    exec_reporter("--update-timings", build_id: queue.build_id)
    refute_empty queue.global_timings

    queue = exec_build("spec_file_splitting", "--file-split-threshold 1")

    assert queue.build_successful?
    refute_empty queue.build_timings
    assert_processed_jobs([
      "./spec/slow_spec.rb[1:2:1]",
      "./spec/slow_spec.rb[1:1]",
      "./spec/fast_spec.rb",
    ], queue)
  end

  def test_suite_with_failures_and_fail_fast
    queue = exec_build("failing_suite", "--fail-fast 1")

    assert_equal 1, queue.fail_fast
    assert queue.build_failed_fast?
    refute queue.build_successful?
    assert_equal queue.fail_fast, queue.example_failures.length +
                                  queue.non_example_errors.length

    # 1 <= unprocessed_jobs <= 2
    # Either Success, Fail (after N requeues), or Fail (after N requeues)
    assert_includes [1, 2], queue.unprocessed_jobs.length

    assert_includes [2, 3], queue.processed_jobs.length
  end

  def test_graceful_shutdown
    pid, queue = start_worker("rescue_exception",
     "--max-requeues=0 --graceful_shutdown_timeout=5")
    queue.wait_until_published
    sleep 1 # make sure the worker has reached `sleep 3` in the spec

    refute queue.exhausted?
    assert queue.worker_heartbeats[queue.worker_id].to_i > 0

    # Send TERM to the supervisor process to trigger worker graceful shutdown
    # that will not be followed by SIGKILL (test sleeps for 3secs)
    Process.kill("TERM", pid)
    Process.wait(pid)
    pid = nil

    # Check that the build is not finished
    assert queue.exhausted?
    refute_empty queue.processed_jobs
    assert_empty queue.workers_withdrawn
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
      rescue StandardError
        nil
      end
      begin
        Process.wait(pid)
      rescue StandardError
        nil
      end
    end
  end

  def test_ungraceful_shutdown_and_exception_swallowing
    # Make sure that ungraceful shutdown while having a reserved job
    # works as expected.
    #
    # Also make sure that the shutdown sequence does not interfere
    # with exception handling in the worker (i.e. that it does not
    # trigger an exception that is eventually handled by rspec).
    pid, queue = start_worker("rescue_exception",
     "--max-requeues=0 --graceful_shutdown_timeout=1")
    queue.wait_until_published
    sleep 1 # make sure the worker has reached `sleep 3` in the spec

    refute queue.exhausted?
    assert queue.worker_heartbeats[queue.worker_id].to_i > 0

    # Send TERM to the supervisor process to trigger worker graceful shutdown
    # that will be followed by SIGKILL after 1 second, making the worker exit
    # while having a reserved job.
    Process.kill("TERM", pid)
    Process.wait(pid)
    pid = nil

    # If the exception is swallowed, the job will be marked as processed
    # So, we check that the build is not finished
    refute queue.exhausted?
    assert_empty queue.processed_jobs
    assert_empty queue.worker_heartbeats
    assert_equal 1, queue.workers_withdrawn[queue.worker_id].to_i
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
      rescue StandardError
        nil
      end
      begin
        Process.wait(pid)
      rescue StandardError
        nil
      end
    end
  end
end
