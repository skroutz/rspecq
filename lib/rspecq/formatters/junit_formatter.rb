require "rspec_junit_formatter"

module RSpecQ
  module Formatters
    # Junit output formatter that handles outputting of requeued examples,
    # the multiple suites per rspecq run.
    class JUnitFormatter < RSpecJUnitFormatter
      def initialize(queue, job, max_requeues, job_index)
        @queue = queue
        @job = job
        @max_requeues = max_requeues
        @requeued_examples = []
        path = "test_results/results-#{ENV['TEST_ENV_NUMBER']}-#{job_index}.xml"
        RSpec::Support::DirectoryMaker.mkdir_p(File.dirname(path))
        output_file = File.new(path, "w")
        super(output_file)
      end

      def example_failed(notification)
        # if it is requeued, store the notification
        if @queue.requeueable_job?(notification.example.id, @max_requeues)
          @requeued_examples << notification.example
        end
      end

      private

      def example_count
        @summary_notification.example_count - @requeued_examples.size
      end

      def failure_count
        @summary_notification.failure_count - @requeued_examples.size
      end

      def examples
        @examples_notification.notifications.reject do |example_notification|
          @requeued_examples.include?(example_notification.example)
        end
      end
    end
  end
end
