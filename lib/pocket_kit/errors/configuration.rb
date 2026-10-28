module PocketKit
  module Errors
    class Configuration
      # The environment variable holding the command, split like a shell would
      # but never run through one. The piece is off until this is set, and off
      # while the variable is unset, blank, or malformed.
      attr_accessor :command_env

      # The app's name, first in every report's text: "<heading> error (source: request)".
      attr_accessor :heading

      # Passed as `--request-id <prefix>-<uuid>`, so the receiver can drop repeats.
      attr_accessor :request_id_prefix

      # Exit statuses that count as sent. 3 means "saved but not yet announced".
      attr_accessor :sent_exit_codes

      # Seconds a fingerprint's repeats are only counted after it is sent.
      attr_accessor :group_window

      # Which errors are reported: unhandled request exceptions, Active Job
      # exceptions, and errors posted by the page's script.
      attr_accessor :requests, :jobs, :browser

      # Called with the controller; return false to refuse page errors with a 404.
      attr_accessor :enabled

      # The class the page-error endpoint inherits from, so the app's own
      # sign-in and other filters apply to it.
      attr_accessor :parent_controller

      def initialize
        @command_env = nil
        @heading = "App"
        @request_id_prefix = "errors"
        @sent_exit_codes = [ 0, 3 ]
        @group_window = 600
        @requests = true
        @jobs = true
        @browser = true
        @enabled = ->(_controller) { true }
        @parent_controller = "ApplicationController"
      end
    end
  end
end
