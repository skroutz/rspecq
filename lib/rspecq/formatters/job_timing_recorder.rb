module RSpecQ
  module Formatters
    # Persists each job's timing (in seconds). Those timings are used when
    # determining the ordering in which jobs are scheduled (slower jobs will
    # be enqueued first).
    class JobTimingRecorder
      def initialize(queue, job)
        @queue = queue
        @job = job
      end

      def dump_summary(summary)
        @queue.record_build_timing(@job, Float(summary.duration))
      end
    end
  end
end
