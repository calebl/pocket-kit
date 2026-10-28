PocketKit.configure do |config|
  config.feedback.command_env = "DUMMY_FEEDBACK_COMMAND"
  config.feedback.heading = "Dummy feedback"
  config.feedback.request_id_prefix = "dummy-feedback"
  config.feedback.hidden_fields = [ :note_id ]
  config.feedback.enabled = ->(controller) { controller.request.cookies["hide_feedback"].blank? }
  config.feedback.context_lines = lambda do |controller|
    note_id = controller.params[:note_id].to_s
    note_id.match?(/\A\d+\z/) ? [ "Note: #{note_id}" ] : []
  end

  config.errors.command_env = "DUMMY_ERRORS_COMMAND"
  config.errors.heading = "Dummy"
  config.errors.request_id_prefix = "dummy-errors"
end
