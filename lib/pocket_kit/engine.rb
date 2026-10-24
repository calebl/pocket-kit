require "rails/engine"

module PocketKit
  # Shared wiring for every piece: routes under the engine's mount point, views
  # under app/views/pocket_kit, assets under app/assets (found by Propshaft), and
  # importmap pins from config/importmap.rb.
  class Engine < ::Rails::Engine
    isolate_namespace PocketKit

    initializer "pocket_kit.importmap", before: "importmap" do |app|
      next unless app.config.respond_to?(:importmap)

      app.config.importmap.paths << root.join("config/importmap.rb")
      app.config.importmap.cache_sweepers << root.join("app/assets/javascripts")
    end
  end
end
