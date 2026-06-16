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

    # Register the admin order-page partial (shows the chosen Paczkomat +
    # the "create label" action). Deduped so dev reloads don't stack it.
    config.after_initialize do
      if Rails.application.config.respond_to?(:spree_admin)
        partials = Rails.application.config.spree_admin.order_page_sidebar_partials
        partials << "spree/admin/orders/furgonetka_point" unless partials.include?("spree/admin/orders/furgonetka_point")
      end
    end
  end
end
