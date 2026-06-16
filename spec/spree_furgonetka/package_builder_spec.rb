RSpec.describe SpreeFurgonetka::PackageBuilder do
  let(:config) { SpreeFurgonetka::Configuration.new.tap { |c| c.sender = { name: "Shop", city: "Warsaw" } } }

  it "maps an order to the Furgonetka package payload" do
    order = build_fake_order(point: "KRA01M", code: "INPOST", weight: 0.3, qty: 2)
    payload = described_class.new(order, config: config).to_h

    pkg = payload[:packages].first
    expect(pkg[:service_type]).to eq("inpost")          # mapped from method code INPOST
    expect(pkg[:pickup_point]).to eq("KRA01M")          # the chosen Paczkomat
    expect(pkg[:sender]).to eq(name: "Shop", city: "Warsaw")
    expect(pkg[:receiver]).to include(
      name: "Jan Kowalski", email: "jan@example.com",
      postcode: "00-001", city: "Warsaw", country_code: "PL"
    )
  end

  it "sizes one parcel from the order items (weight summed across quantity)" do
    order = build_fake_order(weight: 0.3, qty: 2)
    parcel = described_class.new(order, config: config).to_h[:packages].first[:parcels].first
    expect(parcel[:weight]).to eq(0.6)
    expect(parcel[:width]).to eq(23)
    expect(parcel[:height]).to eq(14)
    expect(parcel[:depth]).to eq(8)
  end

  it "omits the pickup point for non-point couriers" do
    order = build_fake_order(point: nil, code: "DPD")
    pkg = described_class.new(order, config: config).to_h[:packages].first
    expect(pkg[:service_type]).to eq("dpd")
    expect(pkg).not_to have_key(:pickup_point)
  end
end
