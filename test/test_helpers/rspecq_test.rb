require_relative "assertions"

# To be subclassed from all test cases.
class RSpecQTest < Minitest::Test
  include TestHelpers
  include TestHelpers::Assertions

  def setup
    Redis.new(host: REDIS_HOST).flushdb
  end
end
