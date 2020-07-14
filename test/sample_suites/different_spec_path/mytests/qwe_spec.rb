RSpec.describe do
  context "foo" do
    describe "abc" do
      it { expect(false).to be false }
    end
  end

  context "bar" do
    describe "dfg" do
      it { expect(true).to be true }
    end
  end
end
