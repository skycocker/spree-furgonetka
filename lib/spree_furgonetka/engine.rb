module SpreeFurgonetka
  class Engine < Rails::Engine
    require "spree/core"
    isolate_namespace Spree
    engine_name "spree_furgonetka"

    config.generators do |g|
      g.test_framework :rspec
    end

    # Load decorators on boot and on each code reload.
    def self.activate
      Dir.glob(root.join("app/**/*_decorator*.rb")) do |c|
        Rails.configuration.cache_classes ? require(c) : load(c)
      end
    end
    config.to_prepare(&method(:activate).to_proc)

    # Register the admin partials: the order-page card (chosen Paczkomat + the
    # "create label" action) and the connection card on Admin → Integracje,
    # where the shop looks for it. Deduped so dev reloads don't stack them.
    ADMIN_PARTIALS = {
      order_page_sidebar_partials: "spree/admin/orders/furgonetka",
      integrations_header_partials: "spree/admin/furgonetka/connection"
    }.freeze

    config.after_initialize do
      if Rails.application.config.respond_to?(:spree_admin)
        ADMIN_PARTIALS.each do |slot, partial|
          partials = Rails.application.config.spree_admin.public_send(slot)
          partials << partial unless partials.include?(partial)
        end
      end
    end
  end
end
