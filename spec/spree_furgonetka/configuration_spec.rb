RSpec.describe SpreeFurgonetka::Configuration do
  subject(:config) { described_class.new }

  it "defaults the OAuth endpoints to the Furgonetka API" do
    expect(config.api_base_url).to eq("https://api.furgonetka.pl")
    expect(config.authorize_url).to eq("https://api.furgonetka.pl/oauth/authorize")
    expect(config.token_url).to eq("https://api.furgonetka.pl/oauth/token")
  end

  it "defaults the courier code and service map" do
    expect(config.courier_service_code).to eq("INPOST")
    expect(config.service_map).to include("INPOST" => "inpost", "DPD" => "dpd", "POCZTA" => "poczta")
  end

  it "reports api/map readiness from the configured secrets" do
    expect(config.api_configured?).to be(false)
    expect(config.map_configured?).to be(false)

    config.client_id = "cid"
    config.client_secret = "secret"
    config.map_api_key = "jwt"
    expect(config.api_configured?).to be(true)
    expect(config.map_configured?).to be(true)
  end

  it "returns nil for credentials when Rails is not present" do
    expect(config.client_id).to be_nil
  end

  it "is configurable via SpreeFurgonetka.configure" do
    SpreeFurgonetka.configure { |c| c.courier_service_code = "PACZKOMAT" }
    expect(SpreeFurgonetka.config.courier_service_code).to eq("PACZKOMAT")
  end
end
