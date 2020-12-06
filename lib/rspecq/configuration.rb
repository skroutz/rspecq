module RSpecQ
  # Use the RSpec parser to parse any command line args intended
  # for rspec such as `-- --format JUnit -o foo.xml` so that we can
  # pass these args to rspec while removing the
  # files_or_dirs_to_run since we want to pull those from the
  # queue. The RSpecQ::Parser will mutate args, removing any rspecq
  # args so that RSpec::Core::Parser only sees the args intended
  # for rspec.
  class Configuration < OpenStruct
    def initialize(args)
      super RSpecQ::Parser.parse!(args)

      self.files_or_dirs_to_run = RSpec::Core::Parser.new(args).parse[:files_or_directories_to_run]
      l = files_or_dirs_to_run.length
      if l.zero?
        self.files_or_dirs_to_run = nil
        self.rspec_args = args
      else
        self.rspec_args = args[0...-l]
      end

      if redis_url
        self.redis_opts = { url: redis_url }
      else
        self.redis_opts = { host: redis_host }
      end
    end

    def report?
      !!report
    end
  end
end
