require_relative "assertions"

# To be subclassed from all test cases.
class RSpecQTest < Minitest::Test
  include TestHelpers
  include TestHelpers::Assertions

  def setup
    Redis.new(REDIS_OPTS).flushdb
  end
end
