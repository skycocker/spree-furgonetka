require "net/http"
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
  class Client
    class Error < StandardError
      attr_reader :code, :body
      def initialize(message, code: nil, body: nil)
        super(message)
        @code = code
        @body = body
      end
    end

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
      store_tokens(data)
      data
    end

    def refresh!
      raise Error, "Not connected to Furgonetka" if @tokens.refresh_token.blank?

      data = token_request(grant_type: "refresh_token", refresh_token: @tokens.refresh_token)
      store_tokens(data)
      data
    end

    def connected?
      @tokens.refresh_token.present?
    end

    # A valid access token, refreshing transparently when it has expired.
    def access_token
      return @tokens.access_token if token_valid?

      refresh!
      @tokens.access_token
    end

    # --- API ----------------------------------------------------------------

    # NOTE: the exact /packages payload + label path are confirmed against the
    # live API on the first authorized call (see README "Verifying"). The shape
    # below follows Furgonetka's REST docs; specs stub the HTTP either way.
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

    def token_valid?
      @tokens.access_token.present? && @tokens.expires_at && @tokens.expires_at > Time.now + 60
    end

    def store_tokens(data)
      @tokens.save(
        access_token: data["access_token"],
        refresh_token: data["refresh_token"].presence || @tokens.refresh_token,
        expires_in: data["expires_in"] || 3600
      )
    end

    def token_request(**form)
      uri = URI(@config.token_url)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(@config.client_id, @config.client_secret)
      request.set_form_data(form)

      response = perform(uri, request)
      body = parse_json(response.body)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error.new("OAuth token request failed (#{response.code}): #{body['message'] || body['error']}",
                        code: response.code, body: body)
      end
      body
    end

    def api_request(method, path, json: nil, query: {}, accept: "application/json", raw: false)
      uri = URI("#{@config.api_base_url}#{path}")
      uri.query = URI.encode_www_form(query) if query.any?

      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      request = klass.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      request["Accept"] = accept
      if json
        request["Content-Type"] = "application/json"
        request.body = json.to_json
      end

      response = perform(uri, request)
      unless response.is_a?(Net::HTTPSuccess)
        body = parse_json(response.body)
        raise Error.new("Furgonetka API error (#{response.code}): #{body['message'] || body['error']}",
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
    end

    def parse_json(body)
      return {} if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
  end
end
