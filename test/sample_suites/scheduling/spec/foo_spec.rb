RSpec.describe "slow spec file (will be split)" do
  it do
    sleep 0.1
    expect(true).to be true
  end

  context "foo" do
    it do
      sleep 0.2
      expect(true).to be true
    end
  end
end
