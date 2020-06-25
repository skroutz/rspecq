module RSpecQ
  module Formatters
    # Increments the example counter after each job.
    class ExampleCountRecorder
      def initialize(queue)
        @queue = queue
      end

      def dump_summary(summary)
        n = summary.examples.count
        @queue.increment_example_count(n) if n > 0
      end
    end
  end
end
