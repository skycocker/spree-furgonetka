RSpec.describe SpreeFurgonetka::Client do
  let(:config) do
    SpreeFurgonetka::Configuration.new.tap do |c|
      c.client_id = "cid"
      c.client_secret = "secret"
    end
  end
  let(:store)  { FakeStore.new }
  let(:tokens) { SpreeFurgonetka::TokenStore.new(store: store) }
  let(:client) { described_class.new(config: config, token_store: tokens) }

  let(:token_url) { "https://api.furgonetka.pl/oauth/token" }

  describe "#authorize_url" do
    it "builds the OAuth authorize URL with the required params" do
      url = client.authorize_url(redirect_uri: "https://example.com/admin/furgonetka/callback", state: "xyz")
      expect(url).to start_with("https://api.furgonetka.pl/oauth/authorize?")
      expect(url).to include("response_type=code")
      expect(url).to include("client_id=cid")
      expect(url).to include("scope=api")
      expect(url).to include("state=xyz")
      expect(url).to include(CGI.escape("https://example.com/admin/furgonetka/callback"))
    end
  end

  describe "#exchange_code" do
    it "exchanges the code for tokens and persists them" do
      stub = stub_request(:post, token_url)
             .with(basic_auth: %w[cid secret],
                   body: hash_including("grant_type" => "authorization_code", "code" => "the-code"))
             .to_return(status: 200, body: {
               access_token: "AT1", refresh_token: "RT1", expires_in: 3600
             }.to_json, headers: { "Content-Type" => "application/json" })

      client.exchange_code(code: "the-code", redirect_uri: "https://example.com/cb")

      expect(stub).to have_been_requested
      expect(tokens.access_token).to eq("AT1")
      expect(tokens.refresh_token).to eq("RT1")
      expect(tokens.expires_at).to be > Time.now
    end

    it "raises a descriptive error on failure" do
      stub_request(:post, token_url).to_return(status: 401, body: { message: "bad code" }.to_json)
      expect { client.exchange_code(code: "x", redirect_uri: "y") }
        .to raise_error(SpreeFurgonetka::Client::Error, /bad code/)
    end
  end

  describe "#access_token" do
    it "returns the stored token without an HTTP call when still valid" do
      tokens.save(access_token: "VALID", refresh_token: "RT", expires_in: 3600)
      expect(client.access_token).to eq("VALID")
      expect(a_request(:post, token_url)).not_to have_been_made
    end

    it "refreshes transparently when the access token has expired" do
      tokens.save(access_token: "OLD", refresh_token: "RT", expires_in: -10) # already expired
      stub_request(:post, token_url)
        .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "RT"))
        .to_return(status: 200, body: { access_token: "NEW", refresh_token: "RT2", expires_in: 3600 }.to_json)

      expect(client.access_token).to eq("NEW")
      expect(tokens.refresh_token).to eq("RT2")
    end
  end

  describe "#refresh!" do
    it "raises when not connected" do
      expect { client.refresh! }.to raise_error(SpreeFurgonetka::Client::Error, /Not connected/)
    end
  end

  describe "#connected?" do
    it "is true only when a refresh token is stored" do
      expect(client.connected?).to be(false)
      tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600)
      expect(client.connected?).to be(true)
    end
  end

  describe "#create_package" do
    before { tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600) }

    it "POSTs the FLAT payload with a Bearer token and returns the parsed package" do
      stub = stub_request(:post, "https://api.furgonetka.pl/packages")
             .with(headers: { "Authorization" => "Bearer AT", "Content-Type" => "application/json" },
                   body: hash_including("service_id" => 12345678, "receiver" => hash_including("point" => "KRA01M")))
             .to_return(status: 201, body: {
               packages: [{ package_id: 987, parcels: [{ package_no: "TRK123" }] }]
             }.to_json, headers: { "Content-Type" => "application/json" })

      result = client.create_package(service_id: 12345678, receiver: { point: "KRA01M" }, parcels: [{ weight: 0.5 }])

      expect(stub).to have_been_requested
      expect(result["packages"].first["package_id"]).to eq(987)
    end

    it "raises Client::Error with the API message on failure" do
      stub_request(:post, "https://api.furgonetka.pl/packages")
        .to_return(status: 422, body: { message: "invalid receiver" }.to_json)
      expect { client.create_package(service_id: 1) }
        .to raise_error(SpreeFurgonetka::Client::Error, /invalid receiver/)
    end
  end

  describe "#service_id_for" do
    before { tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600) }

    it "resolves a service string to the account-specific numeric id" do
      stub_request(:get, "https://api.furgonetka.pl/account/services")
        .with(headers: { "Authorization" => "Bearer AT" })
        .to_return(status: 200, body: {
          services: [{ id: 12345670, service: "dpd" }, { id: 12345678, service: "inpost" }]
        }.to_json, headers: { "Content-Type" => "application/json" })

      expect(client.service_id_for("inpost")).to eq(12345678)
      expect(client.service_id_for("dpd")).to eq(12345670)
      expect(client.service_id_for("unknown")).to be_nil
    end
  end

  describe "#package_label" do
    before { tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600) }

    it "returns raw PDF bytes" do
      stub_request(:get, "https://api.furgonetka.pl/packages/987/label?file_format=pdf")
        .with(headers: { "Authorization" => "Bearer AT", "Accept" => "application/pdf" })
        .to_return(status: 200, body: "%PDF-1.4 bytes")

      expect(client.package_label(987)).to eq("%PDF-1.4 bytes")
    end
  end
end
