require "pocket_kit/version"
require "pocket_kit/engine"

# Each piece lives in its own file and adds its own settings to PocketKit.
require "pocket_kit/feedback"

module PocketKit
  # Yields PocketKit so an initializer can set each piece's options:
  #
  #   PocketKit.configure do |config|
  #     config.feedback.heading = "My app feedback"
  #   end
  def self.configure
    yield self
  end
end
