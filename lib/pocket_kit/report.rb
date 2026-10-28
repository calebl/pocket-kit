require "json"
require "time"

module PocketKit
  # The one JSON report every piece can hand to the local command, whether it
  # comes from Rails, a plain Python app (python/pocket_kit.py), or the page.
  # See "The report format" in the README for every field.
  module Report
    VERSION = 1

    # A note typed into the feedback dialog. `text` is the note itself and
    # `message` the same human-readable message the text format sends.
    def self.feedback(app:, text:, message:, screen:, context: [], device: {}, now: Time.now)
      {
        version: VERSION, kind: "feedback", app: app, source: "browser", occurred_at: timestamp(now),
        screen: screen, text: message, note: text, context: context, device: device
      }
    end

    # One error, standing for `group[:count]` occurrences of the same fingerprint.
    def self.error(app:, source:, error_class:, message:, backtrace:, group:, screen: nil, page: nil, context: [],
                   now: Time.now)
      {
        version: VERSION, kind: "error", app: app, source: source, occurred_at: timestamp(now),
        screen: screen, page: page,
        text: error_text(app, source, error_class, message, backtrace, group),
        context: context,
        error: { class: error_class, message: message, backtrace: backtrace },
        group: group.merge(first_seen: timestamp(group[:first_seen]), last_seen: timestamp(group[:last_seen]))
      }.compact
    end

    def self.to_json(report)
      "#{JSON.generate(report)}\n"
    end

    def self.timestamp(time)
      time.utc.iso8601(3)
    end

    def self.error_text(app, source, error_class, message, backtrace, group)
      lines = [ "#{app} error (source: #{source})", "", "#{error_class}: #{message}", *backtrace.first(10).map { "  #{_1}" } ]
      if group[:count] > 1
        lines += [ "", "Seen #{group[:count]} times since #{timestamp(group[:first_seen])}" ]
      end
      "#{lines.join("\n")}\n"
    end

    private_class_method :timestamp, :error_text
  end
end
