module SpreeFurgonetka
  # Maps a Spree::Order to the Furgonetka "create package" payload: receiver from
  # the order's ship address, the pickup point the customer chose at checkout,
  # one parcel sized from the order, and the courier service from the selected
  # shipping method's code. Sender comes from configuration.
  #
  # The field names follow Furgonetka's REST docs; confirm against the live API
  # on the first authorized call (see README "Verifying the label flow").
  class PackageBuilder
    def initialize(order, config: SpreeFurgonetka.config)
      @order = order
      @config = config
    end

    def to_h
      {
        packages: [
          {
            service_type: service_type,
            sender: @config.sender,
            receiver: receiver,
            parcels: [parcel],
            pickup_point: pickup_point
          }.compact
        ]
      }
    end

    # The Paczkomat / pickup point the customer selected at checkout.
    def pickup_point
      meta = @order.public_metadata
      meta.is_a?(Hash) ? meta["furgonetka_point"].presence : nil
    end

    private

    def service_type
      code = @order.shipments.flat_map(&:shipping_rates).detect(&:selected)&.shipping_method&.code ||
             @order.shipments.first&.shipping_method&.code
      @config.service_map[code] || code&.downcase
    end

    def receiver
      address = @order.ship_address
      {
        name: address.full_name,
        email: @order.email,
        phone: address.phone,
        street: address.address1,
        postcode: address.zipcode,
        city: address.city,
        country_code: address.country&.iso
      }
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
