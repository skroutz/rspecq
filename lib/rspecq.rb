require "rspec/core"
require "sentry-ruby"

module RSpecQ
  # If a worker haven't executed an example for more than WORKER_LIVENESS_SEC
  # seconds, it is considered dead and its reserved work will be put back
  # to the queue to be picked up by another worker.
  WORKER_LIVENESS_SEC = 60.0
end

require_relative "rspecq/formatters/example_count_recorder"
require_relative "rspecq/formatters/failure_recorder"
require_relative "rspecq/formatters/job_timing_recorder"
require_relative "rspecq/formatters/junit_formatter"
require_relative "rspecq/formatters/worker_heartbeat_recorder"

require_relative "rspecq/queue"
require_relative "rspecq/reporter"
require_relative "rspecq/version"
require_relative "rspecq/worker"
