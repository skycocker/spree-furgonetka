require "spree_furgonetka/version"
require "spree_furgonetka/configuration"
require "spree_furgonetka/token_store"
require "spree_furgonetka/client"
require "spree_furgonetka/package_builder"
require "spree_furgonetka/engine" if defined?(Rails::Engine)

module SpreeFurgonetka
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield(config)
    end

    # Convenience: a client bound to the default token store.
    def client
      Client.new
    end
  end
end
