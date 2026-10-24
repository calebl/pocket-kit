module PocketKit
  # Hands a note typed into the feedback dialog to the command configured by
  # PocketKit.feedback.command_env.
  #
  # No shell. The variable is split into a fixed argument array once, the
  # request id and `--json -` are appended as further arguments, and the message
  # goes on the command's stdin. Shell metacharacters stay literal arguments.
  #
  # What is sent: the typed text, the screen as `controller#action` (checked
  # against the app's routes), the app's context_lines, and a "Device:" block of
  # what the browser reports about itself (each field checked and capped).
  #
  # A note counts as sent only when the command exits with one of
  # sent_exit_codes. Anything else, including a missing command, is a failure
  # and leaves the dialog open with the text still in it.
  class FeedbackController < PocketKit.feedback.parent_controller.constantize
    MAX_LENGTH = 2000
    NOTES_PER_MINUTE = 5
    COMMAND_TIMEOUT = 10
    TERMINATION_GRACE = 1
    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # One store for the process, so the limit holds even where the app's cache
    # stores nothing (as in tests).
    RATE_STORE = ActiveSupport::Cache::MemoryStore.new

    helper PocketKit::Feedback::Helper

    before_action :require_enabled
    rate_limit to: NOTES_PER_MINUTE, within: 1.minute, only: :create, store: RATE_STORE, with: -> { reject }

    def create
      text = params[:text].to_s.strip
      screen = params[:screen].to_s
      request_id = params[:request_id].to_s

      valid?(text, screen, request_id) && sent?(text, screen, request_id) ? accept : reject
    end

    private

    def require_enabled
      head :not_found unless Feedback.enabled?(self)
    end

    def valid?(text, screen, request_id)
      text.present? && text.length <= MAX_LENGTH &&
        Feedback.screens.include?(screen) && request_id.match?(UUID_FORMAT)
    end

    def sent?(text, screen, request_id)
      body = Feedback.message(text: text, screen: screen, context: Array(PocketKit.feedback.context_lines.call(self)),
                              device: Feedback.device(params[:device]))
      command = [ *Feedback.command, "--request-id", "#{PocketKit.feedback.request_id_prefix}-#{request_id}",
                  "--json", "-" ]
      status = run_command(command, body)
      status && PocketKit.feedback.sent_exit_codes.include?(status.exitstatus)
    rescue SystemCallError
      false
    end

    def run_command(command, body)
      input, writer = IO.pipe
      pid = Process.spawn(*command, in: input, out: File::NULL, err: File::NULL)
      input.close
      writer_thread = Thread.new do
        writer.write(body)
      rescue IOError, SystemCallError
        nil
      ensure
        writer.close
      end

      status = wait_for(pid, COMMAND_TIMEOUT)
      terminate(pid) unless status
      status
    ensure
      input&.close unless input&.closed?
      writer&.close unless writer&.closed?
      writer_thread&.join
    end

    def wait_for(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = Process.wait2(pid, Process::WNOHANG)
        return result.last if result
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end

    def terminate(pid)
      Process.kill("TERM", pid)
      return if wait_for(pid, TERMINATION_GRACE)

      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end

    # The configured hidden fields as posted, so a fresh form carries them again.
    def hidden_fields
      PocketKit.feedback.hidden_fields.each_with_object({}) do |name, fields|
        value = params[name]
        fields[name] = value if value.is_a?(String) && value.present?
      end
    end

    # A fresh form, closed, with "Sent" beside the button.
    def accept
      render turbo_stream: turbo_stream.replace(Feedback::DOM_ID, partial: "pocket_kit/feedback/feedback",
                                                                  locals: { screen: params[:screen].to_s,
                                                                            fields: hidden_fields, status: :sent })
    end

    # Leaves the dialog open with the typed text in it, and says so inside it.
    def reject
      render turbo_stream: turbo_stream.replace(Feedback::STATUS_DOM_ID, partial: "pocket_kit/feedback/status",
                                                                         locals: { status: :failed }),
             status: :unprocessable_content
    end
  end
end
