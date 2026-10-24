require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "propshaft"
require "importmap-rails"
require "turbo-rails"
require "stimulus-rails"
require "pocket_kit"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "dummy-secret-key-base-for-tests-only"
    config.hosts.clear
    config.logger = Logger.new(nil)
    config.action_controller.allow_forgery_protection = false
    config.action_dispatch.show_exceptions = :rescuable
    config.active_support.deprecation = :raise
  end
end
