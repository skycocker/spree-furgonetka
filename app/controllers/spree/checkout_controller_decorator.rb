module Spree
  # Saves the customer's chosen Furgonetka pickup point (picked via the Map
  # widget at the delivery step) onto the order, and requires it when the
  # configured point-based shipping method (default code INPOST) is selected.
  module CheckoutControllerDecorator
    def update
      if @order && @order.state == "delivery"
        store_furgonetka_point
        if furgonetka_point_method_selected? && furgonetka_point_value.blank?
          flash[:error] = Spree.t(:paczkomat_required)
          return redirect_to spree.checkout_state_path(@order.token, @order.state)
        end
      end
      super
    end

    private

    def furgonetka_point_value
      @order.public_metadata.is_a?(Hash) ? @order.public_metadata["furgonetka_point"] : nil
    end

    def store_furgonetka_point
      code = params.dig(:order, :furgonetka_point).to_s.strip.first(64)
      return if code.blank?

      name = params.dig(:order, :furgonetka_point_name).to_s.strip.first(255)
      meta = (@order.public_metadata || {}).merge(
        "furgonetka_point" => code,
        "furgonetka_point_name" => name
      )
      @order.update_column(:public_metadata, meta)
    end

    def furgonetka_point_method_selected?
      attrs = params.dig(:order, :shipments_attributes)
      return false if attrs.blank?

      rate_ids = attrs.values.filter_map { |s| s[:selected_shipping_rate_id].presence }
      return false if rate_ids.empty?

      Spree::ShippingRate.where(id: rate_ids).joins(:shipping_method)
                         .where(spree_shipping_methods: { code: SpreeFurgonetka.config.courier_service_code }).exists?
    end
  end

  CheckoutController.prepend(CheckoutControllerDecorator)
end
