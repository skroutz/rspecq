RSpec.describe do
  it do
    sleep 0.6
    expect(true).to be true
  end

  context "foo" do
    it do
      sleep 0.6
      expect(true).to be true
    end
  end
end
