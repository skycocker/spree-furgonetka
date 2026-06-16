# Standalone unit/integration suite for the gem's library code (OAuth client,
# package builder, configuration, token store). Runs without a full Spree app;
# Furgonetka HTTP is stubbed with WebMock. Request/feature specs that exercise
# the Spree controllers/views require a dummy app (see README "Testing").
require "active_support/all"
require "webmock/rspec"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "spree_furgonetka"

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  # Fresh global configuration for each example.
  config.before do
    SpreeFurgonetka.instance_variable_set(:@config, nil)
  end
end
