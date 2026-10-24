require "shellwords"
require "pocket_kit/engine"
require "pocket_kit/feedback/configuration"
require "pocket_kit/feedback/helper"

module PocketKit
  # The feedback piece settings, set from an initializer.
  def self.feedback
    @feedback ||= Feedback::Configuration.new
  end

  # A small button that opens a dialog; the note typed into it is handed to a
  # local command named by an environment variable. See
  # PocketKit::FeedbackController for how the command is run.
  module Feedback
    DOM_ID = "pocket_kit_feedback".freeze
    STATUS_DOM_ID = "pocket_kit_feedback_status".freeze

    # What the browser says about the device, filled in by the dialog's script
    # as the note is sent. Each value is kept only if it matches its pattern;
    # anything else is dropped, never passed on. The label is what the
    # "Device:" block calls it.
    DEVICE_FIELDS = {
      user_agent: [ "Browser", /\A[[:print:]]{1,300}\z/ ],
      screen: [ "Screen", /\A\d{1,5}x\d{1,5}\z/ ],
      viewport: [ "Viewport", /\A\d{1,5}x\d{1,5}\z/ ],
      visual_viewport: [ "Visual viewport", /\A\d{1,5}x\d{1,5}\z/ ],
      pixel_ratio: [ "Pixel ratio", /\A\d{1,2}(\.\d{1,4})?\z/ ],
      standalone: [ "Home screen app", /\A(true|false)\z/ ],
      color_scheme: [ "Color scheme", /\A(light|dark)\z/ ]
    }.freeze

    # The configured command as an argument array, or nil when there is none.
    def self.command
      value = ENV.fetch(PocketKit.feedback.command_env, "")
      value.strip.empty? ? nil : Shellwords.split(value)
    rescue ArgumentError
      nil
    end

    # Whether the button shows and the endpoint answers for this request.
    def self.enabled?(controller)
      command.present? && PocketKit.feedback.enabled.call(controller) ? true : false
    end

    # Every `controller#action` the app routes to, so a posted screen can be checked.
    def self.screens
      Rails.application.routes.routes.filter_map do |route|
        controller, action = route.defaults.values_at(:controller, :action)
        "#{controller}##{action}" if controller && action
      end.to_set
    end

    # The message on the command's stdin.
    def self.message(text:, screen:, context: [], device: {})
      lines = [ "#{PocketKit.feedback.heading} (screen: #{screen})", *context ]
      note = "#{lines.join("\n")}\n\n#{text}\n"
      return note if device.empty?

      "#{note}\nDevice:\n#{device.map { |field, value| "#{DEVICE_FIELDS[field].first}: #{value}" }.join("\n")}\n"
    end

    # The device fields that pass their pattern, in DEVICE_FIELDS order.
    def self.device(params)
      return {} unless params.respond_to?(:key?) && params.respond_to?(:[])

      DEVICE_FIELDS.each_with_object({}) do |(field, (_label, pattern)), kept|
        value = params[field]
        kept[field] = value.strip if value.is_a?(String) && value.strip.match?(pattern)
      end
    end
  end

  class Engine
    initializer "pocket_kit.feedback.helper" do
      ActiveSupport.on_load(:action_controller_base) { helper PocketKit::Feedback::Helper }
    end
  end
end
