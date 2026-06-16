require_relative "lib/spree_furgonetka/version"

Gem::Specification.new do |spec|
  spec.name        = "spree_furgonetka"
  spec.version     = SpreeFurgonetka::VERSION
  spec.summary     = "Furgonetka shipping integration for Spree"
  spec.description  = "Furgonetka integration for Spree storefronts: a checkout point-picker " \
                      "(InPost Paczkomaty etc. via Furgonetka's Map widget, no InPost account/NIP), " \
                      "and OAuth2 auto-labels (create shipment + label + tracking from the admin)."
  spec.author      = "skycocker"
  spec.email       = "mike21@aol.pl"
  spec.homepage    = "https://github.com/skycocker/spree-furgonetka"
  spec.license     = "GPL-3.0-or-later"

  spec.required_ruby_version = ">= 3.0"
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files       = Dir["{app,config,lib}/**/*", "README.md", "LICENSE"]
  spec.require_path = "lib"

  spree_version = ">= 5.0"
  spec.add_dependency "spree_admin", spree_version
  spec.add_dependency "spree_core", spree_version
  spec.add_dependency "spree_storefront", spree_version

  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
  spec.add_development_dependency "activesupport", ">= 7.0"
end
