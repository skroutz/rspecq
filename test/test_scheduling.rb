require "test_helpers"

class TestScheduling < RSpecQTest
  def test_scheduling_with_timings_simple
    worker = new_worker("timings")
    silent { worker.work }
    worker.queue.update_global_timings

    assert_queue_well_formed(worker.queue)

    worker = new_worker("timings")
    # update_global_timings is not triggered
    queue = worker.queue
    silent { worker.try_publish_queue!(queue) }

    assert_equal [
      "./test/sample_suites/timings/spec/very_slow_spec.rb",
      "./test/sample_suites/timings/spec/slow_spec.rb",
      "./test/sample_suites/timings/spec/medium_spec.rb",
      "./test/sample_suites/timings/spec/fast_spec.rb",
      "./test/sample_suites/timings/spec/very_fast_spec.rb"
    ], queue.unprocessed_jobs
  end

  def test_scheduling_with_timings_and_splitting
    worker = new_worker("scheduling")
    silent { worker.work }
    worker.queue.update_global_timings

    assert_queue_well_formed(worker.queue)

    # 1st run with timings, the slow file will be split
    worker = new_worker("scheduling")
    worker.file_split_threshold = 0.2
    silent { worker.work }
    worker.queue.update_global_timings

    assert_queue_well_formed(worker.queue)

    assert_processed_jobs([
      "./test/sample_suites/scheduling/spec/bar_spec.rb",
      "./test/sample_suites/scheduling/spec/foo_spec.rb[1:1]",
      "./test/sample_suites/scheduling/spec/foo_spec.rb[1:2:1]",
    ], worker.queue)

    # 2nd run with timings; individual example jobs will also have timings now
    worker = new_worker("scheduling")
    worker.file_split_threshold = 0.2
    silent { worker.try_publish_queue!(worker.queue) }

    assert_equal [
      "./test/sample_suites/scheduling/spec/foo_spec.rb[1:2:1]",
      "./test/sample_suites/scheduling/spec/foo_spec.rb[1:1]",
      "./test/sample_suites/scheduling/spec/bar_spec.rb",
    ], worker.queue.unprocessed_jobs
  end

  def test_untimed_jobs_scheduled_in_the_middle
    worker = new_worker("scheduling_untimed/spec/foo")
    silent { worker.work }
    worker.queue.update_global_timings

    assert_queue_well_formed(worker.queue)
    assert worker.queue.build_successful?
    refute_empty worker.queue.global_timings

    worker = new_worker("scheduling_untimed")
    silent { worker.try_publish_queue!(worker.queue) }
    assert_equal [
      "./test/sample_suites/scheduling_untimed/spec/foo/bar_spec.rb",
      "./test/sample_suites/scheduling_untimed/spec/foo/foo_spec.rb",
      "./test/sample_suites/scheduling_untimed/spec/bar/untimed_spec.rb",
      "./test/sample_suites/scheduling_untimed/spec/foo/zxc_spec.rb",
      "./test/sample_suites/scheduling_untimed/spec/foo/baz_spec.rb",
    ], worker.queue.unprocessed_jobs
  end

  def test_splitting_with_deprecation_warning
    worker = new_worker("deprecation_warning")
    silent { worker.work }
    worker.queue.update_global_timings

    assert_queue_well_formed(worker.queue)
    assert worker.queue.build_successful?
    refute_empty worker.queue.global_timings

    worker = new_worker("deprecation_warning")
    worker.file_split_threshold = 0.2
    silent { worker.work }

    assert_queue_well_formed(worker.queue)
    assert worker.queue.build_successful?
    assert_processed_jobs([
      "./test/sample_suites/deprecation_warning/spec/foo_spec.rb[1:1]",
      "./test/sample_suites/deprecation_warning/spec/foo_spec.rb[1:2]",
    ], worker.queue)
  end
end
