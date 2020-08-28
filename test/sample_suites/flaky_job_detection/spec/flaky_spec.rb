RSpec.describe do
  it "is flaky and passes the 3rd time" do
    $tries_a ||= 0
    $tries_a += 1

    expect($tries_a).to eq 3
  end

  it { expect(true).to be true }

  it "is flaky and passes the 2nd time" do
    $tries_b ||= 0
    $tries_b += 1

    expect($tries_b).to eq 2
  end
end
