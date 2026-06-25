module Spree
  module Admin
    # OAuth connection (authorization-code) + label creation for Furgonetka.
    class FurgonetkaController < Spree::Admin::BaseController
      # GET /admin/furgonetka/connect — kick off the one-time consent.
      def connect
        state = SecureRandom.hex(16)
        session[:furgonetka_oauth_state] = state
        url = SpreeFurgonetka.client.authorize_url(redirect_uri: callback_redirect_uri, state: state)
        redirect_to url, allow_other_host: true
      end

      # GET /admin/furgonetka/callback — Furgonetka returns ?code & ?state here.
      def callback
        if params[:state].blank? || params[:state] != session.delete(:furgonetka_oauth_state)
          return redirect_to spree.admin_orders_path, flash: { error: Spree.t("furgonetka.invalid_state") }
        end

        SpreeFurgonetka.client.exchange_code(code: params[:code], redirect_uri: callback_redirect_uri)
        redirect_to spree.admin_orders_path, flash: { success: Spree.t("furgonetka.connected") }
      rescue SpreeFurgonetka::Client::Error => e
        redirect_to spree.admin_orders_path, flash: { error: "Furgonetka: #{e.message}" }
      end

      # POST /admin/orders/:order_id/furgonetka/label — create the shipment.
      def create_label
        order = Spree::Order.find_by!(number: params[:order_id])
        response = SpreeFurgonetka.client.create_package(SpreeFurgonetka::PackageBuilder.new(order).to_h)

        package = Array(response["packages"]).first || response
        parcel = Array(package["parcels"]).first || {}
        meta = (order.public_metadata || {}).merge(
          "furgonetka_package_id" => package["package_id"] || package["id"],
          "furgonetka_tracking" => parcel["package_no"] || package["tracking_number"] || package["tracking"]
        ).compact
        order.update_column(:public_metadata, meta)

        redirect_back fallback_location: spree.edit_admin_order_path(order),
                      flash: { success: Spree.t("furgonetka.label_created") }
      rescue SpreeFurgonetka::Client::Error => e
        redirect_back fallback_location: spree.admin_orders_path,
                      flash: { error: "Furgonetka: #{e.message}" }
      end

      private

      def callback_redirect_uri
        spree.admin_furgonetka_callback_url
      end
    end
  end
end
