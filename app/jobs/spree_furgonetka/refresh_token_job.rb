module SpreeFurgonetka
  # Keeps the Furgonetka OAuth session alive. Nothing else refreshes it unless a
  # label is created, and refresh tokens last at most 3 months — a quiet spell
  # longer than that used to kill the connection silently. Schedule it in the
  # host app's config/recurring.yml; most runs only read the store row.
  class RefreshTokenJob < Spree::BaseJob
    def perform
      return unless SpreeFurgonetka.config.api_configured?

      result = SpreeFurgonetka.client.keep_alive!
      Rails.logger.info("[spree_furgonetka] token keep-alive: #{result}") if result == :refreshed
      result
    rescue SpreeFurgonetka::Client::NotConnected => e
      # A rejected session is already marked "reconnect required" for the
      # admin; retrying can't help until someone reconnects, so don't fail.
      return :not_connected unless e.is_a?(SpreeFurgonetka::Client::ReauthorizationRequired)

      Rails.logger.warn("[spree_furgonetka] Furgonetka session needs reconnecting: #{e.message}")
      :reconnect_required
    end
  end
end
