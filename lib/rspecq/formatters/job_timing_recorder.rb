module RSpecQ
  module Formatters
    class JobTimingRecorder
      def initialize(queue, job)
        @queue = queue
        @job = job
      end

      def dump_summary(summary)
        @queue.record_timing(@job, Float(summary.duration))
      end
    end
  end
end
