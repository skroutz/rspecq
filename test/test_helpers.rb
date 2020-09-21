require "minitest/autorun"
require "securerandom"
require "rspecq"

module TestHelpers
  REDIS_OPTS = { host: "127.0.0.1" }.freeze
  EXEC_CMD = "bundle exec rspecq".freeze

  def rand_id
    SecureRandom.hex(4)
  end

  def new_worker(path)
    w = RSpecQ::Worker.new(
      build_id: rand_id,
      worker_id: rand_id,
      redis_opts: REDIS_OPTS
    )
    w.files_or_dirs_to_run = suite_path(path)
    w
  end

  def exec_build(path, args = "")
    worker_id = rand_id
    build_id = rand_id

    Dir.chdir(suite_path(path)) do
      out = `#{EXEC_CMD} --worker #{worker_id} --build #{build_id} #{args}`
      puts out if ENV["RSPECQ_DEBUG"]
    end

    assert_equal 0, $?.exitstatus

    queue = RSpecQ::Queue.new(build_id, worker_id, REDIS_OPTS)
    assert_queue_well_formed(queue)

    queue
  end

  def suite_path(path)
    File.join("test", "sample_suites", path)
  end

  # Returns the worker pid
  def start_worker(build_id:, suite:, worker_id: rand_id)
    Process.spawn(
      "#{EXEC_CMD} -w #{worker_id} -b #{build_id}",
      chdir: suite_path(suite),
      out: (ENV["RSPECQ_DEBUG"] ? :out : File::NULL)
    )
  end

  # Supresses stdout of the code provided in the block
  def silent
    if ENV["RSPECQ_DEBUG"]
      yield
      return
    end

    begin
      orig_out = $stdout.clone
      orig_err = $stderr.clone
      $stdout.reopen(File::NULL, "w")
      $stderr.reopen(File::NULL, "w")
      yield
    ensure
      $stdout.reopen(orig_out)
      $stderr.reopen(orig_err)
    end
  end
end

require_relative "test_helpers/rspecq_test"
