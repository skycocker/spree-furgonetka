require "ostruct"

# Minimal stand-in for Spree::Store used by TokenStore (private_metadata +
# update_column), so the OAuth/token logic is testable without a database.
class FakeStore
  attr_reader :private_metadata

  def initialize(metadata = {})
    @private_metadata = metadata
  end

  def update_column(column, value)
    @private_metadata = value if column == :private_metadata
    true
  end
end

# Builds an order double shaped like the bits PackageBuilder reads.
def build_fake_order(point: "KRA01M", code: "INPOST", weight: 0.3, qty: 2)
  country = OpenStruct.new(iso: "PL")
  address = OpenStruct.new(full_name: "Jan Kowalski", phone: "+48600100200",
                           address1: "Example St 1", zipcode: "00-001",
                           city: "Warsaw", country: country)
  variant = OpenStruct.new(weight: weight, depth: 8, width: 23, height: 14)
  line_item = OpenStruct.new(variant: variant, quantity: qty)
  method = OpenStruct.new(code: code)
  rate = OpenStruct.new(selected: true, shipping_method: method)
  shipment = OpenStruct.new(shipping_rates: [rate], shipping_method: method)
  OpenStruct.new(
    public_metadata: { "furgonetka_point" => point }.compact,
    email: "jan@example.com",
    ship_address: address,
    line_items: [line_item],
    shipments: [shipment]
  )
end
