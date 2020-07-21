RSpec.describe do
  it do
    $tries ||= 0
    $tries += 1

    expect($tries).to eq 3
  end
end
