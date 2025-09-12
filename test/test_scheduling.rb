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
    worker.early_push_max_jobs = 0 # Disable early yielding to ensure a fair scheduling
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

  def test_early_yielding_jobs_before_publishing
    # 1st run to populate timings so that we trigger the test splitting
    worker = new_worker("scheduling")
    worker.populate_timings = true
    silent { worker.work }
    assert_queue_well_formed(worker.queue)

    # Setup a thread to monitor Redis commands before triggering a
    # second run
    redis_commands = ::Queue.new
    monitoring_thread = Thread.new do
      rspecq_redis.monitor do |line|
        next if line.nil?

        # Select commands #push_jobs uses
        redis_commands << line if line['"rpush"'] && line[":queue:unprocessed"]
        redis_commands << line if line['"set"'] && line[RSpecQ::Queue::STATUS_READY]
      end
    end

    # 2nd run, the slow file will be split and yielded later
    worker = new_worker("scheduling")
    worker.file_split_threshold = 0.2
    silent { worker.work }

    # Gather redis commands and stop monitoring
    monitoring_thread.kill
    monitoring_thread.join

    commands = []
    commands << redis_commands.shift until redis_commands.empty?

    assert_equal 3, commands.size # 1 yielded rpush + 1 (rpush + ready)
    assert_match '"rpush"', commands[0]
    assert_match '"rpush"', commands[1]
    assert_match RSpecQ::Queue::STATUS_READY, commands.last
  end

  def test_disabled_early_yielding_jobs_before_publishing
    # 1st run to populate timings so that we trigger the test splitting
    worker = new_worker("scheduling")
    worker.populate_timings = true
    silent { worker.work }
    assert_queue_well_formed(worker.queue)

    # Setup a thread to monitor Redis commands before triggering a
    # second run
    redis_commands = ::Queue.new
    monitoring_thread = Thread.new do
      rspecq_redis.monitor do |line|
        next if line.nil?

        # Select commands #push_jobs uses
        redis_commands << line if line['"rpush"'] && line[":queue:unprocessed"]
        redis_commands << line if line['"set"'] && line[RSpecQ::Queue::STATUS_READY]
      end
    end

    # 2nd run, the slow file will be split and yielded in a single step
    # since early_push_max_jobs is 0 (disabled)
    worker = new_worker("scheduling")
    worker.file_split_threshold = 0.2
    worker.early_push_max_jobs = 0 # Disable early yielding!
    silent { worker.work }

    # Gather redis commands and stop monitoring
    monitoring_thread.kill
    monitoring_thread.join

    commands = []
    commands << redis_commands.shift until redis_commands.empty?

    assert_equal 2, commands.size # Only a single (rpush + ready)
    assert_match '"rpush"', commands.first
    assert_match RSpecQ::Queue::STATUS_READY, commands.last
  end
end
