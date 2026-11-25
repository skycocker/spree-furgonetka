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
    # The order's shipping method resolves to no service on this Furgonetka
    # account — a mapping problem (service_map / the method's code), raised
    # before Furgonetka gets a package without a service_id.
    class UnknownService < Client::Error
      attr_reader :shipping_method_code, :service_name

      def initialize(shipping_method_code, service_name)
        @shipping_method_code = shipping_method_code
        @service_name = service_name
        super("No Furgonetka service #{service_name.inspect} on this account " \
              "(shipping method code #{shipping_method_code.inspect})")
      end
    end

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

    # The Paczkomat / pickup point the customer selected at checkout. Only for
    # the point method: a customer who picked a locker and then switched to the
    # courier leaves the point behind in the metadata.
    def pickup_point
      return nil unless shipping_method_code == @config.courier_service_code

      meta = @order.public_metadata
      meta.is_a?(Hash) ? meta["furgonetka_point"].presence : nil
    end

    def shipping_method_code
      @order.shipments.flat_map(&:shipping_rates).detect(&:selected)&.shipping_method&.code ||
        @order.shipments.first&.shipping_method&.code
    end

    # Whether the admin offers "create label" for this order (locker or courier).
    def label_supported?
      @config.label_method?(shipping_method_code)
    end

    # The Furgonetka service string the label will be bought with ("inpost",
    # "dpd", …) — shown next to the button so a wrong mapping is visible.
    def service_name
      code = shipping_method_code
      @config.service_map[code] || code&.downcase
    end

    private

    # Numeric, account-specific service id for the order's shipping method.
    def service_id
      @client.service_id_for(service_name) || raise(UnknownService.new(shipping_method_code, service_name))
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
