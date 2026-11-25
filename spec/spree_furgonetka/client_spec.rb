RSpec.describe SpreeFurgonetka::Client do
  let(:config) do
    SpreeFurgonetka::Configuration.new.tap do |c|
      c.client_id = "cid"
      c.client_secret = "secret"
    end
  end
  let(:store)  { FakeStore.create }
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

    it "restores a session that needed reconnecting" do
      tokens.save(access_token: "OLD", refresh_token: "DEAD", expires_in: -10)
      tokens.mark_reconnect_required("invalid_grant", refresh_token: "DEAD")
      stub_request(:post, token_url)
        .to_return(status: 200, body: { access_token: "AT1", refresh_token: "RT1", expires_in: 2_678_400 }.to_json)

      client.exchange_code(code: "the-code", redirect_uri: "https://example.com/cb")

      expect(client.session).to have_attributes(connected?: true, reconnect_required?: false)
      expect(client.session.authorized_at).to be_within(5).of(Time.now)
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
      expect { client.refresh! }.to raise_error(SpreeFurgonetka::Client::NotConnected, /Not connected/)
    end

    it "refreshes even while the access token is still valid" do
      tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600)
      stub_request(:post, token_url)
        .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "RT"))
        .to_return(status: 200, body: { access_token: "AT2", refresh_token: "RT2", expires_in: 2_678_400 }.to_json)

      client.refresh!

      expect(tokens.session).to have_attributes(access_token: "AT2", refresh_token: "RT2")
      expect(tokens.expires_at).to be_within(5).of(Time.now + 2_678_400)
    end
  end

  describe "when Furgonetka rejects the refresh token" do
    # league/oauth2-server's answer to an expired, revoked or reused token.
    let(:invalid_grant) do
      { status: 400, body: { error: "invalid_grant", error_description: "The refresh token is invalid.",
                             hint: "Token has expired" }.to_json }
    end

    before do
      tokens.save(access_token: "OLD", refresh_token: "DEAD", expires_in: -10)
      stub_request(:post, token_url).to_return(invalid_grant)
    end

    it "raises ReauthorizationRequired with Furgonetka's explanation" do
      expect { client.access_token }
        .to raise_error(SpreeFurgonetka::Client::ReauthorizationRequired, /The refresh token is invalid/)
    end

    it "drops the dead session, so the admin offers reconnecting instead of a label" do
      expect { client.access_token }.to raise_error(SpreeFurgonetka::Client::ReauthorizationRequired)

      expect(client.connected?).to be(false)
      expect(client.session.reconnect_required?).to be(true)
      expect(client.session.reconnect_reason).to include("invalid_grant")
    end

    it "doesn't send the dead refresh token again" do
      expect { client.access_token }.to raise_error(SpreeFurgonetka::Client::ReauthorizationRequired)
      expect { client.access_token }.to raise_error(SpreeFurgonetka::Client::ReauthorizationRequired)

      expect(a_request(:post, token_url)).to have_been_made.once
    end

    it "treats the older invalid_request answer about the refresh token the same way" do
      stub_request(:post, token_url).to_return(
        status: 401, body: { error: "invalid_request", message: "The refresh token is invalid." }.to_json
      )
      expect { client.refresh! }.to raise_error(SpreeFurgonetka::Client::ReauthorizationRequired)
    end
  end

  it "keeps the session when the OAuth app credentials are refused (reconnecting wouldn't help)" do
    tokens.save(access_token: "OLD", refresh_token: "RT", expires_in: -10)
    stub_request(:post, token_url)
      .to_return(status: 401, body: { error: "invalid_client", error_description: "Client authentication failed" }.to_json)

    expect { client.access_token }.to raise_error(SpreeFurgonetka::Client::Error, /Client authentication failed/) { |e|
      expect(e).not_to be_a(SpreeFurgonetka::Client::NotConnected)
    }
    expect(tokens.refresh_token).to eq("RT")
  end

  describe "concurrent refreshes (Puma workers + Solid Queue)" do
    # Furgonetka refresh tokens are single-use: a second refresh with the same
    # token is refused, which used to kill the session.
    it "spends the refresh token once; the other caller picks up the rotated tokens" do
      tokens.save(access_token: "OLD", refresh_token: "RT1", expires_in: -10)
      spent = Queue.new
      stub_request(:post, token_url).to_return do |request|
        refresh_token = URI.decode_www_form(request.body).to_h["refresh_token"]
        spent << refresh_token
        sleep 0.2 # hold the lock long enough for the other thread to queue up
        if refresh_token == "RT1" && spent.size == 1
          { status: 200, body: { access_token: "NEW", refresh_token: "RT2", expires_in: 2_678_400 }.to_json }
        else
          { status: 400, body: { error: "invalid_grant", error_description: "The refresh token is invalid." }.to_json }
        end
      end

      results = Array.new(2) do
        Thread.new do
          described_class.new(config: config, token_store: SpreeFurgonetka::TokenStore.new(store: FakeStore.find(store.id)))
                         .access_token
        end
      end.map(&:value)

      expect(results).to eq(%w[NEW NEW])
      expect(spent.size).to eq(1)
      expect(tokens.session).to have_attributes(refresh_token: "RT2", connected?: true)
    end
  end

  describe "#keep_alive!" do
    let(:refreshed) { { access_token: "AT2", refresh_token: "RT2", expires_in: 2_678_400 }.to_json }

    it "does nothing when not connected" do
      expect(client.keep_alive!(within: 7 * 86_400)).to eq(:not_connected)
    end

    it "leaves a token that is far from expiring alone" do
      tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 20 * 86_400)

      expect(client.keep_alive!(within: 7 * 86_400)).to eq(:fresh)
      expect(a_request(:post, token_url)).not_to have_been_made
    end

    it "refreshes ahead of expiry, rotating the refresh token" do
      tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3 * 86_400)
      stub_request(:post, token_url)
        .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "RT"))
        .to_return(status: 200, body: refreshed)

      expect(client.keep_alive!(within: 7 * 86_400)).to eq(:refreshed)
      expect(tokens.session).to have_attributes(access_token: "AT2", refresh_token: "RT2")
    end

    it "defaults to the configured refresh_ahead window" do
      config.refresh_ahead = 4 * 86_400
      tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 5 * 86_400)

      expect(client.keep_alive!).to eq(:fresh)
    end
  end

  describe "#connected?" do
    it "is true only when a refresh token is stored" do
      expect(client.connected?).to be(false)
      tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600)
      expect(client.connected?).to be(true)
    end
  end

  describe "#disconnect!" do
    it "forgets the session" do
      tokens.save(access_token: "AT", refresh_token: "RT", expires_in: 3600)
      client.disconnect!
      expect(client.session).to have_attributes(connected?: false, reconnect_required?: false)
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

    it "surfaces Furgonetka's field errors, which come without a top-level message" do
      stub_request(:post, "https://api.furgonetka.pl/packages").to_return(status: 400, body: {
        errors: [{ path: "receiver.phone", message: "Nieprawidłowy numer telefonu" },
                 { path: "parcels[0].weight", message: "Za duża waga" }]
      }.to_json)

      expect { client.create_package(service_id: 1) }.to raise_error(SpreeFurgonetka::Client::Error) { |e|
        expect(e.code).to eq("400")
        expect(e.details).to eq("receiver.phone: Nieprawidłowy numer telefonu; parcels[0].weight: Za duża waga")
        expect(e.message).to include("receiver.phone: Nieprawidłowy numer telefonu")
      }
    end

    it "refreshes and retries once when the access token was revoked (401)" do
      stub_request(:post, "https://api.furgonetka.pl/packages")
        .with(headers: { "Authorization" => "Bearer AT" })
        .to_return(status: 401, body: { code: "unauthorized", message: "Token revoked" }.to_json)
      stub_request(:post, token_url)
        .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "RT"))
        .to_return(status: 200, body: { access_token: "AT2", refresh_token: "RT2", expires_in: 2_678_400 }.to_json)
      retried = stub_request(:post, "https://api.furgonetka.pl/packages")
                .with(headers: { "Authorization" => "Bearer AT2" })
                .to_return(status: 201, body: { package_id: 5 }.to_json)

      expect(client.create_package(service_id: 1)).to eq("package_id" => 5)
      expect(retried).to have_been_requested.once
    end

    it "raises NetworkError when Furgonetka can't be reached" do
      stub_request(:post, "https://api.furgonetka.pl/packages").to_timeout
      expect { client.create_package(service_id: 1) }
        .to raise_error(SpreeFurgonetka::Client::NetworkError, /Could not reach Furgonetka/)
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
