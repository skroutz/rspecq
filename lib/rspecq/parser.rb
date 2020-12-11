require "optparse"

module RSpecQ
  class Parser
    DEFAULT_REDIS_HOST = "127.0.0.1".freeze
    DEFAULT_REPORT_TIMEOUT = 3600 # 1 hour
    DEFAULT_MAX_REQUEUES = 3
    DEFAULT_QUEUE_WAIT_TIMEOUT = 30
    DEFAULT_FAIL_FAST = 0

    def self.parse!(args)
      new(args).parse!
    end

    attr_reader :args, :opts

    def initialize(args)
      @args = args
      @opts = {}
    end

    # This method mutates `args` in order to allow both rspecq and
    # rspec options to be passed to rspecq. ["--build", "foo",
    # "--", "--pattern", "bar"] will set `build: "foo"` for rspecq
    # options and leave ["--pattern", "bar"] to be passed to rspec
    def parse!
      parse_args!
      parse_env

      # rubocop:disable Style/RaiseArgs, Layout/EmptyLineAfterGuardClause
      raise OptionParser::MissingArgument.new(:build) if opts[:build].nil?
      raise OptionParser::MissingArgument.new(:worker) if !opts[:report] && opts[:worker].nil?
      # rubocop:enable Style/RaiseArgs, Layout/EmptyLineAfterGuardClause

      opts
    end

    private

    def parse_args!
      OptionParser.new do |o|
        name = File.basename($PROGRAM_NAME)

        o.banner = <<~BANNER
          NAME:
              #{name} - Optimally distribute and run RSpec suites among parallel workers

          USAGE:
              #{name} [<options>] [spec files or directories]
        BANNER

        o.separator ""
        o.separator "OPTIONS:"

        o.on("-b", "--build ID", "A unique identifier for the build. Should be " \
            "common among workers participating in the same build.") do |v|
          opts[:build] = v
        end

        o.on("-w", "--worker ID", "An identifier for the worker. Workers " \
            "participating in the same build should have distinct IDs.") do |v|
          opts[:worker] = v
        end

        o.on("--seed SEED", "The RSpec seed. Passing the seed can be helpful in " \
          "many ways i.e reproduction and testing.") do |v|
          opts[:seed] = v
        end

        o.on("-r", "--redis HOST", "Redis host to connect to " \
            "(default: #{DEFAULT_REDIS_HOST}).") do |v|
          puts "--redis is deprecated. Use --redis-host or --redis-url instead"
          opts[:redis_host] = v
        end

        o.on("--redis-host HOST", "Redis host to connect to " \
            "(default: #{DEFAULT_REDIS_HOST}).") do |v|
          opts[:redis_host] = v
        end

        o.on("--redis-url URL", "The URL of the Redis host to connect to " \
            "(e.g.: redis://127.0.0.1:6379/0).") do |v|
          opts[:redis_url] = v
        end

        o.on("--update-timings", "Update the global job timings key with the "     \
            "timings of this build. Note: This key is used as the basis for job " \
            "scheduling.") do |v|
          opts[:timings] = v
        end

        o.on("--file-split-threshold N", Integer, "Split spec files slower than N " \
            "seconds and schedule them as individual examples.") do |v|
          opts[:file_split_threshold] = v
        end

        o.on("--report", "Enable reporter mode: do not pull tests off the queue; " \
                        "instead print build progress and exit when it's "        \
                        "finished.\n#{o.summary_indent * 9} "                       \
                        "Exits with a non-zero status code if there were any "    \
                        "failures.") do |v|
          opts[:report] = v
        end

        o.on("--report-timeout N", Integer, "Fail if build is not finished after " \
            "N seconds. Only applicable if --report is enabled "                  \
            "(default: #{DEFAULT_REPORT_TIMEOUT}).") do |v|
          opts[:report_timeout] = v
        end

        o.on("--max-requeues N", Integer, "Retry failed examples up to N times "   \
            "before considering them legit failures "                             \
            "(default: #{DEFAULT_MAX_REQUEUES}).") do |v|
          opts[:max_requeues] = v
        end

        o.on("--queue-wait-timeout N", Integer, "Time to wait for a queue to be "   \
            "ready before considering it failed "                                  \
            "(default: #{DEFAULT_QUEUE_WAIT_TIMEOUT}).") do |v|
          opts[:queue_wait_timeout] = v
        end

        o.on("--fail-fast N", Integer, "Abort build with a non-zero status code " \
            "after N failed examples.") do |v|
          opts[:fail_fast] = v
        end

        o.on("--reproduction", "Enable reproduction mode: run rspec on the given files " \
            "and examples in the exact order they are given. Incompatible with " \
            "--timings.") do |v|
          opts[:reproduction] = v
        end

        o.on("--include-suite-in-filename", "Add suite count to output file names so " \
          "so that all suites are presented in output files.") do |v|
          opts[:include_suite_in_filename] = v
        end

        o.on_tail("-h", "--help", "Show this message.") do
          puts o
          exit
        end

        o.on_tail("-v", "--version", "Print the version and exit.") do
          puts "#{name} #{RSpecQ::VERSION}"
          exit
        end
      end.parse!(args)
    end

    def parse_env
      opts[:build] ||= ENV["RSPECQ_BUILD"]
      opts[:worker] ||= ENV["RSPECQ_WORKER"]
      opts[:seed] ||= ENV["RSPECQ_SEED"]
      opts[:redis_host] ||= ENV["RSPECQ_REDIS"] || DEFAULT_REDIS_HOST
      opts[:timings] = opts.fetch(:timings, env_set?("RSPECQ_UPDATE_TIMINGS"))
      opts[:file_split_threshold] ||= Integer(ENV["RSPECQ_FILE_SPLIT_THRESHOLD"] || 9_999_999)
      opts[:report] = opts.fetch(:report, env_set?("RSPECQ_REPORT"))
      opts[:report_timeout] ||= Integer(ENV["RSPECQ_REPORT_TIMEOUT"] || DEFAULT_REPORT_TIMEOUT)
      opts[:max_requeues] ||= Integer(ENV["RSPECQ_MAX_REQUEUES"] || DEFAULT_MAX_REQUEUES)
      opts[:queue_wait_timeout] ||= Integer(ENV["RSPECQ_QUEUE_WAIT_TIMEOUT"] || DEFAULT_QUEUE_WAIT_TIMEOUT)
      opts[:redis_url] ||= ENV["RSPECQ_REDIS_URL"]
      opts[:fail_fast] ||= Integer(ENV["RSPECQ_FAIL_FAST"] || DEFAULT_FAIL_FAST)
      opts[:reproduction] ||= env_set?("RSPECQ_REPRODUCTION")
      opts[:include_suite_in_filename] ||= env_set?("RSPECQ_INCLUDE_SUITE_IN_FILENAME")
    end

    def env_set?(var)
      ["1", "true"].include?(ENV[var])
    end
  end
end
