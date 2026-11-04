module PocketKit
  module Replay
    class Configuration
      # Whether pages record a replay: true, false (the default), or a lambda
      # called with the controller.
      attr_accessor :enabled

      # rrweb masks everything typed into inputs unless this is true.
      attr_accessor :show_typed_text

      # Where replays are saved; nil means tmp/pocket_kit/replays under the app.
      attr_accessor :directory

      # The largest replay accepted with a report, in bytes of JSON. The page
      # drops its oldest events to fit; a bigger one is left out of the report.
      attr_accessor :max_bytes

      # How many replay files are kept; the oldest are deleted past this.
      attr_accessor :keep

      # Called with the controller; return false to answer the replay pages with
      # a 404. The default allows only requests from this machine.
      attr_accessor :viewer

      # The class the replay pages inherit from, so the app's own sign-in and
      # other filters apply to them.
      attr_accessor :parent_controller

      def initialize
        @enabled = false
        @show_typed_text = false
        @directory = nil
        @max_bytes = 1_000_000
        @keep = 100
        @viewer = ->(controller) { controller.request.local? }
        @parent_controller = "ApplicationController"
      end
    end
  end
end
