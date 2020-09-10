$stderr.puts "I'm a warning!"

describe "A slow spec file to be splitted" do
  it do
    sleep 0.1
    expect(true).to be true
  end

  it do
    sleep 0.2
    expect(true).to be true
  end
end
