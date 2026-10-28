require "securerandom"
require "pocket_kit/engine"
require "pocket_kit/command"
require "pocket_kit/report"
require "pocket_kit/errors/configuration"
require "pocket_kit/errors/groups"
require "pocket_kit/errors/outbox"
require "pocket_kit/errors/helper"

module PocketKit
  # The errors piece settings, set from an initializer.
  def self.errors
    @errors ||= Errors::Configuration.new
  end

  # Reports unhandled request exceptions, Active Job exceptions, and errors
  # from the page to a local command, as the JSON report described in the
  # README. Repeats are grouped (see Errors::Groups). Nothing leaves the
  # machine: the command is the only place a report goes.
  module Errors
    COMMAND_TIMEOUT = 10
    BACKTRACE_LINES = 20

    # The Rails error reporter source for unhandled request exceptions.
    REQUEST_SOURCE = "application.action_dispatch".freeze

    def self.command
      Command.from_env(PocketKit.errors.command_env)
    end

    def self.enabled?
      command.present?
    end

    def self.groups
      @groups ||= Groups.new(window: PocketKit.errors.group_window)
    end

    def self.outbox
      @outbox ||= Outbox.new
    end

    # Forgets every group, e.g. between tests or after group_window changes.
    def self.reset!
      @groups = nil
    end

    # Waits for queued reports to reach the command.
    def self.flush(timeout = 30)
      outbox.flush(timeout)
    end

    # Reports an exception raised on the server. Returns false when the piece
    # is off, true when a report was queued, nil when it was held as a repeat.
    def self.report_exception(error, source:, context: [])
      backtrace = Array(error.backtrace)
      backtrace = Rails.backtrace_cleaner.clean(backtrace).presence || backtrace if defined?(Rails.backtrace_cleaner)
      report(error_class: error.class.name, message: error.message.to_s, backtrace: backtrace, source: source,
             context: context)
    end

    # Reports an error the page's script posted, already checked and capped.
    def self.report(error_class:, message:, backtrace:, source:, screen: nil, page: nil, context: [])
      return false unless enabled?

      backtrace = backtrace.drop(1) if source == "browser" && backtrace.first == "#{error_class}: #{message}"
      backtrace = backtrace.first(BACKTRACE_LINES)
      group_store = groups
      group = group_store.record(Groups.fingerprint(error_class, message, backtrace.first))
      return unless group

      settings = PocketKit.errors
      body = Report.to_json(Report.error(app: settings.heading, source: source, error_class: error_class,
                                         message: message, backtrace: backtrace, group: group, screen: screen,
                                         page: page, context: context))
      request_id = "#{settings.request_id_prefix}-#{SecureRandom.uuid}"
      command = self.command
      accepted = outbox.push do
        delivered = false
        begin
          delivered = Command.send_report(command, request_id: request_id, body: body, timeout: COMMAND_TIMEOUT,
                                                    sent_exit_codes: settings.sent_exit_codes)
        ensure
          delivered ? group_store.commit(group) : group_store.rollback(group)
        end
      end
      group_store.rollback(group) unless accepted
      accepted
    end

    # Receives Rails.error reports. Only unhandled request exceptions are
    # reported; errors the app rescued and reported itself are left alone.
    class Subscriber
      def report(error, handled:, severity:, context:, source: nil)
        return if handled || source != REQUEST_SOURCE || !PocketKit.errors.requests

        Errors.report_exception(error, source: "request")
      rescue StandardError
        nil
      end
    end

    # Prepended to ActiveJob::Base: reports an exception that escapes
    # perform_now, after the job's own retry_on, discard_on and rescue_from
    # handlers have had their turn. Queue adapters run jobs through perform_now.
    module JobReporting
      def perform_now
        super
      rescue Exception => error # rubocop:disable Lint/RescueException -- re-raised
        if PocketKit.errors.jobs
          begin
            Errors.report_exception(error, source: "job", context: [ "Job: #{self.class.name}" ])
          rescue StandardError
            nil
          end
        end
        raise
      end
    end
  end

  class Engine
    initializer "pocket_kit.errors" do |app|
      app.executor.error_reporter.subscribe(Errors::Subscriber.new)
      ActiveSupport.on_load(:active_job) { prepend PocketKit::Errors::JobReporting }
      ActiveSupport.on_load(:action_controller_base) { helper PocketKit::Errors::Helper }
    end
  end
end
