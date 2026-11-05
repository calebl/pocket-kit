module PocketKit
  module Replay
    class Configuration
      # Whether pages record a replay: true or false (the default).
      attr_accessor :enabled

      # rrweb masks user-editable text unless this is true.
      attr_accessor :show_typed_text

      # Where replays are saved; nil means tmp/pocket_kit/replays under the app.
      attr_accessor :directory

      # The largest replay accepted with a report, in bytes of JSON. The page
      # drops its oldest events to fit; a bigger one is left out of the report.
      attr_accessor :max_bytes

      # Retention target after files are old enough to prune; recent delivery
      # files can temporarily exceed it.
      attr_accessor :keep

      # How long a replay is kept, in seconds (or a Duration such as 3.days).
      # Older replays are deleted and never served. Default 7 days.
      attr_accessor :max_age

      # Called with the controller; return false to answer the replay pages with
      # a 404. The default allows only requests made on this machine, refusing
      # any request a proxy (such as `tailscale serve`) forwards from elsewhere.
      # Widening it shows recorded screens to whoever it lets in.
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
        @max_age = 7 * 24 * 60 * 60
        @viewer = ->(controller) { Replay.local_request?(controller.request) }
        @parent_controller = "ApplicationController"
      end
    end
  end
end
