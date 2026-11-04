module PocketKit
  module Replay
    module Helper
      # A meta tag that turns recording on for this page: it names the vendored
      # rrweb recorder and carries the masking setting and the size cap. Nothing
      # when replay is off for this request, or when neither feedback nor page
      # errors could send one. Put it in <head>.
      def pocket_kit_replay_tag
        return unless Replay.enabled?(controller)
        return unless Feedback.enabled?(controller) ||
                      (PocketKit.errors.browser && Errors.enabled? && PocketKit.errors.enabled.call(controller))

        settings = PocketKit.replay
        tag.meta(name: "pocket-kit-replay", content: asset_path(Replay::RECORDER),
                 data: { show_typed_text: settings.show_typed_text ? "true" : "false", max_bytes: settings.max_bytes })
      end
    end
  end
end
