require "rspec/core"

module RSpecQ
  MAX_REQUEUES = 3

  # If a worker haven't executed an RSpec example for more than this time
  # (in seconds), it is considered dead and its reserved work will be put back
  # to the queue, to be picked up by another worker.
  WORKER_LIVENESS_SEC = 60.0
end

require_relative "rspecq/formatters/example_count_recorder"
require_relative "rspecq/formatters/failure_recorder"
require_relative "rspecq/formatters/job_timing_recorder"
require_relative "rspecq/formatters/worker_heartbeat_recorder"

require_relative "rspecq/queue"
require_relative "rspecq/reporter"
require_relative "rspecq/worker"

require_relative "rspecq/version"
