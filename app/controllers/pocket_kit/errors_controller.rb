module PocketKit
  # Receives errors the page's script (pocket_kit.js) caught: uncaught errors
  # and unhandled promise rejections. Every field is checked and capped before
  # it is grouped and handed to the command configured by
  # PocketKit.errors.command_env.
  class ErrorsController < PocketKit.errors.parent_controller.constantize
    ERRORS_PER_MINUTE = 30
    CLASS_FORMAT = /\A[\w$.:]{1,100}\z/
    PAGE_FORMAT = /\A\/[[:print:]]{0,299}\z/
    MAX_MESSAGE = 1000
    MAX_STACK = 5000
    MAX_FRAME = 300

    RATE_STORE = ActiveSupport::Cache::MemoryStore.new

    before_action :require_enabled
    rate_limit to: ERRORS_PER_MINUTE, within: 1.minute, only: :create, store: RATE_STORE,
               with: -> { head :too_many_requests }

    def create
      message = clean(params[:message], MAX_MESSAGE)
      return head :unprocessable_content if message.blank? || params[:kind] != "error"

      accepted = Errors.report(error_class: error_class, message: message, backtrace: backtrace, source: "browser",
                               screen: screen, page: page)
      head accepted == false ? :service_unavailable : :accepted
    end

    private

    def require_enabled
      head :not_found unless PocketKit.errors.browser && Errors.enabled? && PocketKit.errors.enabled.call(self)
    end

    def error_class
      value = params[:class]
      value.is_a?(String) && value.match?(CLASS_FORMAT) ? value : "Error"
    end

    def backtrace
      clean(params[:stack], MAX_STACK).to_s.lines.map { _1.strip[0, MAX_FRAME] }.reject(&:empty?)
    end

    def screen
      value = params[:screen]
      value if value.is_a?(String) && Feedback.screens.include?(value)
    end

    def page
      value = params[:page]
      value if value.is_a?(String) && value.match?(PAGE_FORMAT)
    end

    # The text with control characters other than newlines and tabs removed, capped.
    def clean(value, limit)
      value.gsub(/[^[:print:]\n\t]/, "").strip[0, limit] if value.is_a?(String)
    end
  end
end
