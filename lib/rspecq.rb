require "rspec/core"
require "sentry-ruby"

module RSpecQ
  # See configuration and parser for the worker_liveness_sec option.
end

require_relative "rspecq/formatters/example_count_recorder"
require_relative "rspecq/formatters/failure_recorder"
require_relative "rspecq/formatters/job_timing_recorder"
require_relative "rspecq/formatters/junit_formatter"
require_relative "rspecq/formatters/worker_heartbeat_recorder"

require_relative "rspecq/configuration"
require_relative "rspecq/parser"
require_relative "rspecq/queue"
require_relative "rspecq/reporter"
require_relative "rspecq/version"
require_relative "rspecq/worker"
