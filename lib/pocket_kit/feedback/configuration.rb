module PocketKit
  module Feedback
    class Configuration
      # The environment variable holding the command, split like a shell would
      # but never run through one. Unset or blank turns the feedback piece off.
      attr_accessor :command_env

      # The first line of every message: "<heading> (screen: controller#action)".
      attr_accessor :heading

      # Passed as `--request-id <prefix>-<uuid>`, so the receiver can drop repeats.
      attr_accessor :request_id_prefix

      # Exit statuses that count as sent. 3 means "saved but not yet announced".
      attr_accessor :sent_exit_codes

      # Called with the controller; return false to hide the button and answer 404.
      attr_accessor :enabled

      # Called with the receiving controller; returns extra lines placed under the
      # heading, e.g. the record the note was written on.
      attr_accessor :context_lines

      # Names of extra hidden fields the form may carry (passed to the helper as
      # `fields:`), read back by context_lines through `controller.params`.
      attr_accessor :hidden_fields

      # The class the endpoint's controller inherits from, so the app's own
      # sign-in and other filters apply to it.
      attr_accessor :parent_controller

      def initialize
        @command_env = "FEEDBACK_COMMAND"
        @heading = "Feedback"
        @request_id_prefix = "feedback"
        @sent_exit_codes = [ 0, 3 ]
        @enabled = ->(_controller) { true }
        @context_lines = ->(_controller) { [] }
        @hidden_fields = []
        @parent_controller = "ApplicationController"
      end
    end
  end
end
