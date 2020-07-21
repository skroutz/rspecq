require "test_helpers"

class TestEndToEnd < RSpecQTest
  def test_suite_with_legit_failures
    queue = exec_build("failing_suite")

    refute queue.build_successful?

    assert_processed_jobs [
      "./spec/foo_spec.rb",
      "./spec/bar_spec.rb",
      "./spec/bar_spec.rb[1:2]",
    ], queue

   assert_equal 3+RSpecQ::MAX_REQUEUES, queue.example_count

   assert_equal({ "./spec/bar_spec.rb[1:2]" => "3" }, queue.requeued_jobs)
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

    assert_equal({ "./spec/foo_spec.rb[1:1]" => "2" }, queue.requeued_jobs)
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

  def test_timings_update
    queue = exec_build("timings", "--update-timings")

    assert queue.build_successful?

    assert_equal [
      "./spec/very_fast_spec.rb",
      "./spec/fast_spec.rb",
      "./spec/medium_spec.rb",
      "./spec/slow_spec.rb",
      "./spec/very_slow_spec.rb",
    ], queue.timings.sort_by { |k,v| v }.map(&:first)
  end

  def test_timings_no_update
    queue = exec_build("timings")

    assert queue.build_successful?
    assert_empty queue.timings
  end

  def test_spec_file_splitting
    queue = exec_build( "spec_file_splitting", "--update-timings")
    assert queue.build_successful?
    refute_empty queue.timings

    queue = exec_build( "spec_file_splitting", "--file-split-threshold 1")

    assert queue.build_successful?
    refute_empty queue.timings
    assert_processed_jobs([
      "./spec/slow_spec.rb[1:2:1]",
      "./spec/slow_spec.rb[1:1]",
      "./spec/fast_spec.rb",
    ], queue)
  end
end
