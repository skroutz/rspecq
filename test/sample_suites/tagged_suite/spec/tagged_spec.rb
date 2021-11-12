RSpec.describe do
  it "is slow", :slow do
    expect(true).to be true
  end

  it "is fast", :fast do
    expect(true).to be true
  end

  it "is not tagged"do
    expect(true).to be true
  end
end
