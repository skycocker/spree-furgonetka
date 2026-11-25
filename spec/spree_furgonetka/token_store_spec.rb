RSpec.describe SpreeFurgonetka::TokenStore do
  let(:store) { FakeStore.create }
  subject(:tokens) { described_class.new(store: store) }

  it "persists and reads back tokens with an expiry" do
    tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600)

    expect(tokens.access_token).to eq("AT")
    expect(tokens.refresh_token).to eq("RT")
    expect(tokens.expires_at).to be_within(5).of(Time.now + 3600)
    # written through to the backing store
    expect(store.row["furgonetka_refresh_token"]).to eq("RT")
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
    expect(store.row.keys).to be_empty
  end

  describe "with a stale copy of the store (Spree::Store.default is cached)" do
    let(:stale) { FakeStore.find(store.id) }

    before { stale } # loaded before anything below changes the row

    it "reads the current tokens, not the copy's" do
      described_class.new(store: FakeStore.find(store.id))
                     .save(access_token: "AT2", refresh_token: "RT2", expires_in: 3600)

      expect(described_class.new(store: stale).refresh_token).to eq("RT2")
    end

    it "writes only its own keys, keeping metadata other code stored meanwhile" do
      FakeStore.find(store.id).update_column(:private_metadata, "stripe_apple_pay_domain_id" => "apd_1")

      described_class.new(store: stale).save(access_token: "AT", refresh_token: "RT", expires_in: 3600)

      expect(store.row).to include("stripe_apple_pay_domain_id" => "apd_1", "furgonetka_refresh_token" => "RT")
    end
  end

  it "expires the cached store after every write (update_column skips Spree's after_commit)" do
    tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600)
    tokens.clear

    expect(store.cache_clears).to eq(2)
  end

  it "records the consent time only for a fresh authorization" do
    tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600, authorized: true)
    authorized_at = tokens.session.authorized_at
    expect(authorized_at).to be_within(5).of(Time.now)

    tokens.save(access_token: "AT2", refresh_token: "RT2", expires_in: 3600)
    expect(tokens.session.authorized_at).to eq(authorized_at)
    expect(tokens.session.refreshed_at).to be_within(5).of(Time.now)
  end

  describe "#mark_reconnect_required" do
    before { tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600) }

    it "drops the rejected session and keeps the reason for the admin" do
      tokens.mark_reconnect_required("invalid_grant: The refresh token is invalid.", refresh_token: "RT")

      session = tokens.session
      expect(session.connected?).to be(false)
      expect(session.reconnect_required?).to be(true)
      expect(session.reconnect_reason).to eq("invalid_grant: The refresh token is invalid.")
      expect(session.access_token).to be_nil
    end

    it "leaves a session another process has already replaced alone" do
      tokens.save(access_token: "AT2", refresh_token: "RT2", expires_in: 3600)

      expect(tokens.mark_reconnect_required("invalid_grant", refresh_token: "RT")).to be(false)
      expect(tokens.session).to have_attributes(connected?: true, refresh_token: "RT2", reconnect_reason: nil)
    end

    it "is cleared by the next successful save" do
      tokens.mark_reconnect_required("invalid_grant", refresh_token: "RT")
      tokens.save(access_token: "AT3", refresh_token: "RT3", expires_in: 3600, authorized: true)

      expect(tokens.session).to have_attributes(connected?: true, reconnect_required?: false, reconnect_reason: nil)
    end
  end
end
