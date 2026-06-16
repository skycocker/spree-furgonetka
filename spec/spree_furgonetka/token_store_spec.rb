RSpec.describe SpreeFurgonetka::TokenStore do
  let(:store)  { FakeStore.new }
  subject(:tokens) { described_class.new(store: store) }

  it "persists and reads back tokens with an expiry" do
    tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600)

    expect(tokens.access_token).to eq("AT")
    expect(tokens.refresh_token).to eq("RT")
    expect(tokens.expires_at).to be_within(5).of(Time.now + 3600)
    # written through to the backing store
    expect(store.private_metadata["furgonetka_refresh_token"]).to eq("RT")
  end

  it "treats a negative expires_in as already expired" do
    tokens.save(access_token: "AT", refresh_token: "RT", expires_in: -10)
    expect(tokens.expires_at).to be < Time.now
  end

  it "clears stored tokens" do
    tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600)
    tokens.clear
    expect(tokens.access_token).to be_nil
    expect(tokens.refresh_token).to be_nil
  end
end
