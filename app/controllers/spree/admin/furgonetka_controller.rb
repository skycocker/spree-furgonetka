module Spree
  module Admin
    # OAuth connection (authorization-code) + label creation for Furgonetka.
    # The connection's status card lives on Admin → Integracje (registered by
    # the engine); these actions back its buttons and the order-page card.
    class FurgonetkaController < Spree::Admin::BaseController
      # GET /admin/furgonetka/connect — kick off the one-time consent.
      # ?return_to= brings the admin back where they started (e.g. the order).
      def connect
        return redirect_with_error(Spree.t("furgonetka.errors.not_configured")) unless SpreeFurgonetka.config.api_configured?

        state = SecureRandom.hex(16)
        session[:furgonetka_oauth_state] = state
        session[:furgonetka_return_to] = safe_return_to(params[:return_to])
        url = SpreeFurgonetka.client.authorize_url(redirect_uri: callback_redirect_uri, state: state)
        redirect_to url, allow_other_host: true
      end

      # GET /admin/furgonetka/callback — Furgonetka returns ?code & ?state here
      # (or ?error when the consent was refused). This URI is registered with
      # the Furgonetka OAuth app; keep the path.
      def callback
        return_to = session.delete(:furgonetka_return_to).presence || spree.admin_integrations_path

        if params[:state].blank? || params[:state] != session.delete(:furgonetka_oauth_state)
          return redirect_to return_to, flash: { error: Spree.t("furgonetka.invalid_state") }
        end
        if params[:error].present? || params[:code].blank?
          return redirect_to return_to, flash: { error: Spree.t("furgonetka.authorization_denied") }
        end

        SpreeFurgonetka.client.exchange_code(code: params[:code], redirect_uri: callback_redirect_uri)
        redirect_to return_to, flash: { success: Spree.t("furgonetka.connected") }
      rescue SpreeFurgonetka::Client::Error => e
        redirect_to return_to, flash: { error: Spree.t("furgonetka.connect_failed", details: error_message(e)) }
      end

      # POST /admin/furgonetka/refresh — renew the session now; also a way to
      # check the connection without creating a shipment.
      def refresh
        SpreeFurgonetka.client.refresh!
        redirect_to spree.admin_integrations_path, flash: { success: Spree.t("furgonetka.refreshed") }
      rescue SpreeFurgonetka::Client::Error => e
        redirect_with_error(error_message(e))
      end

      # DELETE /admin/furgonetka/disconnect
      def disconnect
        SpreeFurgonetka.client.disconnect!
        redirect_to spree.admin_integrations_path, flash: { success: Spree.t("furgonetka.disconnected") }
      end

      # POST /admin/orders/:order_id/furgonetka/label — create the shipment.
      # Deliberately outside any transaction: a rollback would undo a token
      # rotation Furgonetka has already applied (TokenStore refuses to run
      # inside one). A created package is only "waiting" until it's ordered, so
      # the existing-package check is enough to stop accidental repeats.
      def create_label
        order = Spree::Order.find_by!(number: params[:order_id])
        if (existing = order.public_metadata.to_h["furgonetka_package_id"]).present?
          return redirect_back fallback_location: spree.edit_admin_order_path(order),
                               flash: { error: Spree.t("furgonetka.errors.label_exists", id: existing) }
        end

        client = SpreeFurgonetka.client
        response = client.create_package(SpreeFurgonetka::PackageBuilder.new(order, client: client).to_h)

        package = Array(response["packages"]).first || response
        parcel = Array(package["parcels"]).first || {}
        package_id = package["package_id"] || package["id"]
        meta = (order.reload.public_metadata || {}).merge(
          "furgonetka_package_id" => package_id,
          "furgonetka_tracking" => parcel["package_no"] || package["tracking_number"] || package["tracking"]
        ).compact
        order.update_column(:public_metadata, meta)

        redirect_back fallback_location: spree.edit_admin_order_path(order),
                      flash: { success: Spree.t("furgonetka.label_created", id: package_id) }
      rescue SpreeFurgonetka::Client::Error => e
        redirect_back fallback_location: spree.admin_orders_path, flash: { error: error_message(e) }
      end

      private

      def callback_redirect_uri
        spree.admin_furgonetka_callback_url
      end

      def redirect_with_error(message)
        redirect_to spree.admin_integrations_path, flash: { error: message }
      end

      # Only a path inside the admin, so the callback can't become an open redirect.
      def safe_return_to(value)
        path = value.to_s
        path if path.start_with?("/admin/") && !path.start_with?("//") && !path.include?("\\")
      end

      # The admin reads Polish; Furgonetka's own wording is kept in the message.
      def error_message(error)
        case error
        when SpreeFurgonetka::Client::ReauthorizationRequired
          Spree.t("furgonetka.errors.reconnect_required")
        when SpreeFurgonetka::Client::NotConnected
          Spree.t("furgonetka.errors.not_connected")
        when SpreeFurgonetka::PackageBuilder::UnknownService
          Spree.t("furgonetka.errors.unknown_service", code: error.shipping_method_code.to_s, service: error.service_name.to_s)
        when SpreeFurgonetka::Client::NetworkError
          Spree.t("furgonetka.errors.network")
        else
          Spree.t("furgonetka.errors.api", status: error.code.presence || "—",
                                           details: error.details || error.message)
        end
      end
    end
  end
end
