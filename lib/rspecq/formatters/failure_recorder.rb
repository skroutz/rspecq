module RSpecQ
  module Formatters
    class FailureRecorder
      def initialize(queue, job, max_requeues)
        @queue = queue
        @job = job
        @colorizer = RSpec::Core::Formatters::ConsoleCodes
        @non_example_error_recorded = false
        @max_requeues = max_requeues
      end

      # Here we're notified about errors occuring outside of examples.
      #
      # NOTE: Upon such an error, RSpec emits multiple notifications but we only
      # want the _first_, which is the one that contains the error backtrace.
      # That's why have to keep track of whether we've already received the
      # needed notification and act accordingly.
      def message(n)
        if RSpec.world.non_example_failure && !@non_example_error_recorded
          @queue.record_non_example_error(@job, n.message)
          @non_example_error_recorded = true
        end
      end

      def example_failed(notification)
        example = notification.example

        if @queue.requeue_job(example.id, @max_requeues)
          # HACK: try to avoid picking the job we just requeued; we want it
          # to be picked up by a different worker
          sleep 0.5
          return
        end

        presenter = RSpec::Core::Formatters::ExceptionPresenter.new(
          example.exception, example)

        msg = presenter.fully_formatted(nil, @colorizer)
        msg << "\n"
        msg << @colorizer.wrap(
          "bin/rspec #{example.location_rerun_argument}",
          RSpec.configuration.failure_color)

        msg << @colorizer.wrap(
          " # #{example.full_description}", RSpec.configuration.detail_color)

        @queue.record_example_failure(notification.example.id, msg)
      end
    end
  end
end
