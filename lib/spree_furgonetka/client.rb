require "net/http"
require "openssl"
require "json"
require "uri"

module SpreeFurgonetka
  # Thin Furgonetka REST API client. Handles the OAuth2 authorization-code flow
  # (no stored password) and the calls needed to buy a label: create a package,
  # fetch its label PDF, read its tracking number.
  #
  # HTTP is plain Net::HTTP so it's trivial to stub in specs (WebMock). Token
  # persistence is delegated to a TokenStore so the client is unit-testable
  # without a database.
  #
  # Furgonetka's documented lifetimes (furgonetka.pl/api/oauth): the access
  # token lasts 30 days, the refresh token up to 3 months and is single-use —
  # each refresh returns a new pair and revokes the old one.
  class Client
    class Error < StandardError
      attr_reader :code, :body

      def initialize(message, code: nil, body: nil)
        super(message)
        @code = code
        @body = body
      end

      # Furgonetka's own explanation, as sent: the field errors of a rejected
      # package ("receiver.phone: …"), or an OAuth error description.
      def self.details_from(body)
        payload = body.is_a?(Hash) ? body : {}
        errors = Array(payload["errors"]).filter_map do |error|
          next error.to_s.presence unless error.is_a?(Hash)

          [error["path"].presence, (error["message"].presence || error["code"].presence)].compact.join(": ").presence
        end
        return errors.join("; ") if errors.any?

        payload["error_description"].presence || payload["message"].presence || payload["error"].presence
      end

      def details
        self.class.details_from(body)
      end

      # The OAuth error code ("invalid_grant", "invalid_client", …), if any.
      def oauth_error
        body["error"].presence if body.is_a?(Hash)
      end
    end

    # No session at all: the shop has to connect (or reconnect) in the admin.
    class NotConnected < Error; end

    # Furgonetka refused to refresh the session (expired, revoked or already
    # used refresh token). The stored session has been dropped; only a new
    # consent ("Połącz ponownie") brings the connection back.
    class ReauthorizationRequired < NotConnected; end

    # Furgonetka couldn't be reached at all (DNS, timeout, TLS, reset).
    class NetworkError < Error; end

    NETWORK_ERRORS = [
      IOError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError
    ].freeze

    def initialize(config: SpreeFurgonetka.config, token_store: SpreeFurgonetka::TokenStore.new)
      @config = config
      @tokens = token_store
    end

    # --- OAuth (authorization code) -----------------------------------------

    # URL we send the user to so they log in to Furgonetka and consent.
    def authorize_url(redirect_uri:, state:)
      query = URI.encode_www_form(
        response_type: "code",
        client_id: @config.client_id,
        redirect_uri: redirect_uri,
        scope: "api",
        state: state
      )
      "#{@config.authorize_url}?#{query}"
    end

    # Exchange the one-time code (from the redirect) for tokens and persist them.
    def exchange_code(code:, redirect_uri:)
      data = token_request(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri)
      store_tokens(data, authorized: true)
      data
    end

    # Refreshes now, whatever the access token's expiry (admin "Odnów teraz").
    def refresh!
      locked_refresh { true }
    end

    # Called on a schedule (RefreshTokenJob): refreshes once the access token is
    # within `within` seconds of expiring. Refreshing well ahead of expiry
    # rotates the refresh token long before its own lifetime runs out, so a shop
    # that buys no labels for months stays connected. Returns :not_connected,
    # :fresh or :refreshed.
    def keep_alive!(within: @config.refresh_ahead)
      session = @tokens.session
      return :not_connected unless session.connected?
      return :fresh if session.access_token_valid?(margin: within)

      refreshed = false
      locked_refresh do |current|
        refreshed = !current.access_token_valid?(margin: within)
      end
      refreshed ? :refreshed : :fresh
    end

    def session
      @tokens.session
    end

    def connected?
      session.connected?
    end

    # Forget the session locally. Furgonetka documents no revoke endpoint; the
    # orphaned session simply expires on their side.
    def disconnect!
      @tokens.clear
    end

    # A valid access token, refreshing transparently when it has expired.
    def access_token
      session = @tokens.session
      return session.access_token if session.access_token_valid?

      # Re-checked under the lock: another process may have refreshed meanwhile.
      locked_refresh { |current| !current.access_token_valid? }.access_token
    end

    # --- API ----------------------------------------------------------------

    # The courier services available to this account, each shaped like
    # { "id" => 12345678, "service" => "inpost", "name" => "InPost", ... }.
    # Memoised per client instance.
    def services
      @services ||= Array(api_request(:get, "/account/services")["services"])
    end

    # Resolve a Furgonetka service string ("inpost", "dpd", …) to the numeric
    # service_id the /packages endpoint requires. The ids are account-specific,
    # so they're looked up live rather than hard-coded.
    def service_id_for(service_name)
      return nil if service_name.nil?

      svc = services.find { |s| s["service"] == service_name }
      svc && svc["id"]
    end

    # Create a shipment. Payload is a FLAT object (NOT wrapped in `packages`):
    #   { service_id:, sender:, pickup:, receiver: { …, point: }, parcels: [ … ] }
    # On success Furgonetka returns the created package; see PackageBuilder.
    def create_package(payload)
      api_request(:post, "/packages", json: payload)
    end

    def package(package_id)
      api_request(:get, "/packages/#{package_id}")
    end

    # Returns raw label bytes (PDF).
    def package_label(package_id, file_format: "pdf")
      api_request(:get, "/packages/#{package_id}/label",
                  query: { file_format: file_format }, accept: "application/pdf", raw: true)
    end

    private

    # Refreshes under the token store's lock when the block, given the session
    # as read under that lock, says it's still needed. Returns the session.
    def locked_refresh
      rejected = nil
      @tokens.synchronize do |current|
        unless current.connected?
          raise (current.reconnect_required? ? ReauthorizationRequired : NotConnected), "Not connected to Furgonetka"
        end
        next unless yield(current)

        begin
          data = token_request(grant_type: "refresh_token", refresh_token: current.refresh_token)
        rescue Error => e
          raise unless refresh_token_rejected?(e)

          # Persisted before raising — raising inside the block would roll the
          # mark back along with the lock's transaction.
          @tokens.mark_reconnect_required([e.oauth_error, e.details].compact.uniq.join(": "),
                                          refresh_token: current.refresh_token)
          rejected = e
          next
        end
        store_tokens(data, previous_refresh_token: current.refresh_token)
      end

      if rejected
        raise ReauthorizationRequired.new(["Furgonetka rejected the refresh token", rejected.details].compact.join(": "),
                                          code: rejected.code, body: rejected.body)
      end
      @tokens.session
    end

    # invalid_grant is RFC 6749's answer for an expired, revoked or reused
    # refresh token. Older league/oauth2-server releases (which Furgonetka's
    # `def…` refresh tokens suggest it runs) answered invalid_request instead.
    def refresh_token_rejected?(error)
      case error.oauth_error
      when "invalid_grant" then true
      when "invalid_request" then error.details.to_s.match?(/refresh token/i)
      else false
      end
    end

    def store_tokens(data, previous_refresh_token: nil, authorized: false)
      @tokens.save(
        access_token: data["access_token"],
        refresh_token: data["refresh_token"].presence || previous_refresh_token,
        expires_in: data["expires_in"] || 3600,
        authorized: authorized
      )
    end

    def token_request(**form)
      uri = URI(@config.token_url)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(@config.client_id, @config.client_secret)
      request.set_form_data(form)

      response = perform(uri, request)
      body = parse_json(response.body)
      unless response.is_a?(Net::HTTPSuccess) && body["access_token"].present?
        raise Error.new(["OAuth token request failed (#{response.code})", Error.details_from(body)].compact.join(": "),
                        code: response.code, body: body)
      end
      body
    end

    # A 401 means the request wasn't processed — typically the access token was
    # revoked by a refresh elsewhere — so it is safe to refresh and retry once.
    def api_request(method, path, json: nil, query: {}, accept: "application/json", raw: false, retried: false)
      uri = URI("#{@config.api_base_url}#{path}")
      uri.query = URI.encode_www_form(query) if query.any?

      token = access_token
      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      request = klass.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = accept
      if json
        request["Content-Type"] = "application/json"
        request.body = json.to_json
      end

      response = perform(uri, request)
      if response.is_a?(Net::HTTPUnauthorized) && !retried
        locked_refresh { |current| current.access_token == token || !current.access_token_valid? }
        return api_request(method, path, json: json, query: query, accept: accept, raw: raw, retried: true)
      end

      unless response.is_a?(Net::HTTPSuccess)
        body = parse_json(response.body)
        raise Error.new(["Furgonetka API error (#{response.code})", Error.details_from(body)].compact.join(": "),
                        code: response.code, body: body)
      end
      raw ? response.body : parse_json(response.body)
    end

    def perform(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 25
      http.request(request)
    rescue *NETWORK_ERRORS => e
      raise NetworkError, "Could not reach Furgonetka: #{e.class}: #{e.message}"
    end

    def parse_json(body)
      return {} if body.nil? || body.empty?

      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
