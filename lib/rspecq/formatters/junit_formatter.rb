require "rspec_junit_formatter"
require "pry-byebug"

module RSpecQ
  module Formatters
    # Persists status of examples, so that we can run a single Reporter.
    class JUnitFormatter < RSpecJUnitFormatter
      # def initialize(queue, job, max_requeues)
      def initialize(queue, job, max_requeues, job_index)
        @queue = queue
        @job = job
        @max_requeues = max_requeues
        @requeued_examples =[]
        path = "test_results/results-#{job_index}.xml"
        RSpec::Support::DirectoryMaker.mkdir_p(File.dirname(path))
        output_file = File.new(path, "w")
        super(output_file)
      end

      def example_passed(notification)
        log_notification("example_passed", notification)
      end

      def example_failed(notification)
        # if it is requeued, store the notification
        log_notification("example_failed", notification)
        if @queue.requeueable_job?(notification.example.id, @max_requeues)
          puts "IGNORE from dump... getting requeued"
          @requeued_examples << notification.example
        else
          puts "FAILED - print it in dump"
        end
      end

      def start(notification)
        log_notification("start", notification)
        super
      end

      def stop(notification)
        log_notification("stop", notification)
        super
      end

      def dump_summary(notification)
        log_notification("dump_summary", notification)
        super
      end

      private

      def log_notification(event, notification)
        puts "============"
        puts event
        puts notification.inspect
        puts "============"
      end

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
