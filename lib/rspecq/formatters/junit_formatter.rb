require "rspec_junit_formatter"

module RSpecQ
  module Formatters
    # Junit output formatter that handles outputting of requeued examples,
    # parallel gem, and multiple suites per rspecq run.
    class JUnitFormatter < RSpecJUnitFormatter
      def initialize(queue, job, max_requeues, job_index, path)
        @queue = queue
        @job = job
        @max_requeues = max_requeues
        @requeued_passed_examples = []
        @requeued_failed_examples = []
        path = path.gsub(/{{TEST_ENV_NUMBER}}/,ENV["TEST_ENV_NUMBER"].to_s)
        path = path.gsub(/{{JOB_INDEX}}/, job_index.to_s)
        RSpec::Support::DirectoryMaker.mkdir_p(File.dirname(path))
        output_file = File.new(path, "w")
        super(output_file)
      end

      def example_passed(notification)
        # if it is a requeued run, store the notification
        if !ENV["ERROR_CONTEXT_BASE_PATH"].nil?
          @requeued_passed_examples << notification.example
        end
      end

      def example_failed(notification)
        # if it is a requeued run, store the notification
        if !ENV["ERROR_CONTEXT_BASE_PATH"].nil?
          @requeued_failed_examples << notification.example
        end
      end

      private

      def example_count
        @summary_notification.example_count - (@requeued_passed_examples.size + @requeued_failed_examples.size)
      end

      def failure_count
        @summary_notification.failure_count - @requeued_failed_examples.size
      end

      def examples
        ignore_examples = @requeued_failed_examples.union(@requeued_passed_examples)
        @examples_notification.notifications.reject do |example_notification|
          ignore_examples.map(&:id).include?(example_notification.example.id)
        end
      end
    end
  end
end
