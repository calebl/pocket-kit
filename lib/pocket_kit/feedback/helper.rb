module PocketKit
  module Feedback
    module Helper
      # Renders the feedback button and its dialog, or nothing when the piece is
      # off for this request. `fields` fills the configured hidden_fields.
      def pocket_kit_feedback(screen: "#{controller_path}##{action_name}", fields: {})
        render "pocket_kit/feedback/feedback", screen: screen, fields: fields, status: nil
      end
    end
  end
end
