RSpec.describe SpreeFurgonetka::PackageBuilder do
  let(:config) do
    SpreeFurgonetka::Configuration.new.tap do |c|
      c.sender = { name: "Jane", company: "Shop", email: "shop@example.com",
                   phone: "600100200", street: "Main 1", postcode: "00-001", city: "Warsaw" }
    end
  end
  # Resolves any service string to a fixed numeric id (the real client hits
  # GET /account/services; see client_spec).
  let(:client) { instance_double(SpreeFurgonetka::Client, service_id_for: 12345678) }

  def build(order)
    described_class.new(order, config: config, client: client)
  end

  it "builds a FLAT payload (no `packages` envelope) with the resolved service_id" do
    order = build_fake_order(point: "KRA01M", code: "INPOST", weight: 0.3, qty: 2)
    payload = build(order).to_h

    expect(payload).not_to have_key(:packages)
    expect(payload[:service_id]).to eq(12345678)
    expect(payload.keys).to include(:service_id, :sender, :pickup, :receiver, :parcels)
  end

  it "resolves the numeric service_id from the method code via the client" do
    expect(client).to receive(:service_id_for).with("inpost").and_return(12345678)
    build(build_fake_order(code: "INPOST")).to_h
  end

  it "puts the chosen Paczkomat in receiver.point" do
    payload = build(build_fake_order(point: "KRA01M", code: "INPOST")).to_h
    expect(payload[:receiver][:point]).to eq("KRA01M")
    expect(payload[:receiver]).to include(
      name: "Jan Kowalski", email: "jan@example.com",
      postcode: "00-001", city: "Warsaw", country_code: "PL"
    )
  end

  it "stamps sender + pickup from configuration (both required by the API)" do
    payload = build(build_fake_order).to_h
    expected = { name: "Jane", company: "Shop", email: "shop@example.com", phone: "600100200",
                 street: "Main 1", postcode: "00-001", city: "Warsaw", country_code: "PL" }
    expect(payload[:sender]).to eq(expected)
    expect(payload[:pickup]).to eq(expected)
  end

  it "sizes one parcel from the order items (weight summed across quantity)" do
    parcel = build(build_fake_order(weight: 0.3, qty: 2)).to_h[:parcels].first
    expect(parcel[:weight]).to eq(0.6)
    expect(parcel[:width]).to eq(23)
    expect(parcel[:height]).to eq(14)
    expect(parcel[:depth]).to eq(8)
  end

  it "omits receiver.point for non-Paczkomat couriers" do
    allow(client).to receive(:service_id_for).with("dpd").and_return(12345670)
    payload = build(build_fake_order(point: nil, code: "DPD")).to_h
    expect(payload[:service_id]).to eq(12345670)
    expect(payload[:receiver]).not_to have_key(:point)
  end
end
