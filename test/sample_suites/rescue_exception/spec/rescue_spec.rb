# rubocop:disable Lint/RescueException
RSpec.describe do
  it do
    sleep 3
    expect(false).to be true
  rescue Exception => e # rescue all exceptions, including SystemExit, Interrupt, etc.
    puts "rescued #{e.class}"
    expect(true).to be true
  end
end
# rubocop:enable Lint/RescueException
