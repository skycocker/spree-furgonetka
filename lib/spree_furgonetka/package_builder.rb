module SpreeFurgonetka
  # Maps a Spree::Order to the Furgonetka "create package" payload, verified
  # field-by-field against the live REST API (api.furgonetka.pl):
  #
  #   {
  #     service_id: 12345678,        # numeric, resolved from the method code
  #     sender:   { name:, company:, email:, phone:, street:, postcode:, city:, country_code: },
  #     pickup:   { …same shape… },  # collection / label sender address
  #     receiver: { name:, email:, phone:, street:, postcode:, city:, country_code:, point: },
  #     parcels:  [ { width:, height:, depth:, weight: } ]
  #   }
  #
  # The body is a FLAT object — the `packages: [...]` envelope is only the read
  # format. The chosen Paczkomat goes in `receiver.point`. `sender`/`pickup`
  # come from configuration; the numeric service_id is looked up via the client.
  class PackageBuilder
    def initialize(order, config: SpreeFurgonetka.config, client: SpreeFurgonetka.client)
      @order = order
      @config = config
      @client = client
    end

    def to_h
      {
        service_id: service_id,
        sender: address_block,
        pickup: address_block,
        receiver: receiver,
        parcels: [parcel]
      }
    end

    # The Paczkomat / pickup point the customer selected at checkout.
    def pickup_point
      meta = @order.public_metadata
      meta.is_a?(Hash) ? meta["furgonetka_point"].presence : nil
    end

    private

    # Numeric, account-specific service id for the order's shipping method.
    def service_id
      @client.service_id_for(service_name)
    end

    def service_name
      code = @order.shipments.flat_map(&:shipping_rates).detect(&:selected)&.shipping_method&.code ||
             @order.shipments.first&.shipping_method&.code
      @config.service_map[code] || code&.downcase
    end

    # Sender + pickup address, from configuration (host credentials).
    def address_block
      s = @config.sender || {}
      {
        name: s[:name],
        company: s[:company],
        email: s[:email],
        phone: s[:phone],
        street: s[:street],
        postcode: s[:postcode],
        city: s[:city],
        country_code: s[:country_code] || "PL"
      }
    end

    def receiver
      address = @order.ship_address
      {
        name: address.full_name,
        email: @order.email,
        phone: address.phone,
        street: street_for(address),
        postcode: address.zipcode,
        city: address.city,
        country_code: address.country&.iso || "PL",
        point: pickup_point
      }.compact
    end

    # Furgonetka parses the house number out of the street string and rejects a
    # street with no number, so fold both address lines together — the number
    # sometimes lands in line 2.
    def street_for(address)
      [address.address1, address.address2].map { |s| s.to_s.strip.presence }.compact.join(" ").presence
    end

    # One parcel sized from the order; per-product dimensions/weight come from
    # the product editor. Falls back to small defaults when unset.
    def parcel
      items = @order.line_items
      weight = items.sum { |li| (li.variant.weight.to_f.nonzero? || 0.5) * li.quantity }
      dims = items.map { |li| [li.variant.depth.to_f, li.variant.width.to_f, li.variant.height.to_f] }
      max = ->(i) { (dims.map { |d| d[i] }.max.to_f.nonzero? || 10) }
      {
        width: max.call(1),
        height: max.call(2),
        depth: max.call(0),
        weight: weight.nonzero? || 0.5
      }
    end
  end
end
