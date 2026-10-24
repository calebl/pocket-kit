require_relative "lib/pocket_kit/version"

Gem::Specification.new do |spec|
  spec.name = "pocket_kit"
  spec.version = PocketKit::VERSION
  spec.authors = [ "Caleb LeNoir" ]
  spec.summary = "Small shared pieces for self-hosted phone web apps, as a Rails engine."
  spec.description = "A feedback button that hands notes to a local command, and a documented pattern " \
                     "for running an app on your own machine and reaching it from a phone over a VPN."
  spec.homepage = "https://github.com/calebl/pocket-kit"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["{app,config,lib}/**/*", "LICENSE", "README.md"]

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "turbo-rails", ">= 2.0"
end
