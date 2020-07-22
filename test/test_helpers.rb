require "minitest/autorun"
require "securerandom"
require "rspecq"

module TestHelpers
  REDIS_HOST = "127.0.0.1".freeze
  EXEC_CMD = "bundle exec rspecq"

  def rand_id
    SecureRandom.hex(4)
  end

  def new_worker(path)
    RSpecQ::Worker.new(
      build_id: rand_id,
      worker_id: rand_id,
      redis_host: REDIS_HOST,
      files_or_dirs_to_run: suite_path(path),
    )
  end

  def exec_build(path, args="")
    worker_id = rand_id
    build_id = rand_id

    Dir.chdir(suite_path(path)) do
      out = `#{EXEC_CMD} --worker #{worker_id} --build #{build_id} #{args}`
      puts out if ENV["RSPECQ_DEBUG"]
    end

    assert_equal 0, $?.exitstatus

    queue = RSpecQ::Queue.new(build_id, worker_id, REDIS_HOST)
    assert_queue_well_formed(queue)

    return queue
  end

  def assert_queue_well_formed(queue, msg=nil)
    redis = queue.redis
    heartbeats = redis.zrange(
      queue.send(:key_worker_heartbeats), 0, -1, withscores: true)

    assert queue.published?
    assert queue.exhausted?
    assert_operator heartbeats.size, :>=, 0
    assert heartbeats.all? { |hb| Time.at(hb.last) <= Time.now }
  end

  def assert_build_not_flakey(queue)
    assert_empty queue.requeued_jobs
  end

  def assert_processed_jobs(exp, queue)
    assert_equal exp.sort, queue.processed_jobs.sort
  end

  def suite_path(path)
    File.join("test", "sample_suites", path)
  end

  def start_worker(build_id:, worker_id: rand_id, suite:)
    Process.spawn(
      "#{EXEC_CMD} -w #{worker_id} -b #{build_id}",
      chdir: suite_path(suite),
      out: (ENV["RSPECQ_DEBUG"] ? :out : "/dev/null"),
    )
  end
end

# To be subclassed from all test cases.
class RSpecQTest < Minitest::Test
  include TestHelpers

  def setup
    Redis.new(host: REDIS_HOST).flushdb
  end
end
