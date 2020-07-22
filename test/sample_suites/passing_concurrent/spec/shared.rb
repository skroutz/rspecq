RSpec.shared_examples "kinda slow example" do
  it do
    sleep 2
    expect(true).to be true
  end
end
