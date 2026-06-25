module SpreeFurgonetka
  # Runtime configuration. Secrets are read from the HOST application's Rails
  # credentials (so nothing sensitive lives in this gem) but every value can be
  # overridden — e.g. in tests, or via an initializer.
  #
  #   SpreeFurgonetka.configure do |c|
  #     c.client_id = "..."   # usually left to read from credentials
  #   end
  #
  # Expected host credentials:
  #   furgonetka:
  #     map_api_key:     <JWT for the checkout Map widget, domain-bound>
  #     api_client_id:   <OAuth app Client ID>
  #     api_client_secret: <OAuth app Client Secret>
  class Configuration
    attr_writer :client_id, :client_secret, :map_api_key,
                :api_base_url, :authorize_url, :token_url, :courier_service_code,
                :sender, :service_map

    # Sender / pickup address (nadawca) stamped on every label. The Furgonetka
    # "create package" endpoint requires name, company, email, phone, street,
    # postcode and city. Read from the host credentials by default so the
    # address never lives in the gem:
    #   furgonetka:
    #     sender:
    #       name: "Jane Doe"
    #       company: "Your Shop"
    #       email: "shop@example.com"
    #       phone: "600100200"
    #       street: "Example St 1"
    #       postcode: "00-001"
    #       city: "Warsaw"
    #       country_code: "PL"
    # …or override in an initializer with `c.sender = { ... }`.
    def sender
      @sender ||= (credential(:sender) || {})
    end

    # Maps a Spree shipping-method code to a Furgonetka service string. The
    # string is resolved to the account-specific numeric service_id at send
    # time via GET /account/services. Override in the host app when your
    # shipping-method codes differ (e.g. an InPost courier method).
    def service_map
      @service_map ||= { "INPOST" => "inpost", "DPD" => "dpd", "POCZTA" => "poczta" }
    end

    # Shipping-method code that means "InPost Paczkomat" (drives the picker +
    # the Furgonetka service id). Override if your method uses a different code.
    def courier_service_code
      @courier_service_code ||= "INPOST"
    end

    def api_base_url
      @api_base_url ||= "https://api.furgonetka.pl"
    end

    def authorize_url
      @authorize_url ||= "#{api_base_url}/oauth/authorize"
    end

    def token_url
      @token_url ||= "#{api_base_url}/oauth/token"
    end

    def client_id
      @client_id ||= credential(:api_client_id)
    end

    def client_secret
      @client_secret ||= credential(:api_client_secret)
    end

    def map_api_key
      @map_api_key ||= credential(:map_api_key)
    end

    # True once the OAuth app keys are present (the Map picker needs only the
    # map key; the API/auto-label needs client id + secret).
    def api_configured?
      client_id.present? && client_secret.present?
    end

    def map_configured?
      map_api_key.present?
    end

    private

    def credential(key)
      return nil unless defined?(Rails) && Rails.application
      Rails.application.credentials.dig(:furgonetka, key)
    end
  end
end
