module SpreeFurgonetka
  # Persists the OAuth tokens obtained via the authorization-code flow. We never
  # store the user's account password — only the long-lived refresh token (plus
  # the short-lived access token + its expiry), kept in the default store's
  # private_metadata (server-side only, never rendered).
  class TokenStore
    KEYS = %w[furgonetka_access_token furgonetka_refresh_token furgonetka_token_expires_at].freeze

    def initialize(store: nil)
      @store = store
    end

    def access_token
      read("furgonetka_access_token")
    end

    def refresh_token
      read("furgonetka_refresh_token")
    end

    def expires_at
      value = read("furgonetka_token_expires_at")
      value && Time.at(value.to_f)
    end

    def save(access_token:, refresh_token:, expires_in:)
      write(
        "furgonetka_access_token" => access_token,
        "furgonetka_refresh_token" => refresh_token,
        "furgonetka_token_expires_at" => (Time.now + expires_in.to_i).to_f
      )
    end

    def clear
      write(KEYS.index_with { nil })
    end

    private

    def store
      @store ||= Spree::Store.default
    end

    def read(key)
      meta = store.private_metadata || {}
      meta[key]
    end

    def write(pairs)
      meta = (store.private_metadata || {}).merge(pairs)
      store.update_column(:private_metadata, meta)
    end
  end
end
