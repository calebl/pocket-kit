require "digest"

module PocketKit
  module Errors
    # Groups repeat errors so a burst runs the command once, not once per
    # occurrence. The rule, shared with python/pocket_kit.py:
    #
    # - The fingerprint is the first 16 hex characters of the SHA-256 of
    #   "<class>\n<message>\n<top frame>", where in the message every `0x…` hex
    #   number and every run of digits is replaced by "N" (ids and addresses
    #   differ between repeats; the error does not).
    # - The first occurrence of a fingerprint is sent at once.
    # - Repeats within `window` seconds of the last send are only counted.
    # - The next occurrence after the window is sent, with a count that
    #   includes the repeats held back since the last send.
    #
    # At most MAX_GROUPS fingerprints are remembered; the least recently sent
    # is forgotten first.
    class Groups
      MAX_GROUPS = 500

      def self.fingerprint(error_class, message, top_frame)
        normalized = message.to_s.gsub(/0x\h+/i, "N").gsub(/\d+/, "N")
        Digest::SHA256.hexdigest("#{error_class}\n#{normalized}\n#{top_frame}")[0, 16]
      end

      def initialize(window:)
        @window = window
        @groups = {}
        @mutex = Mutex.new
      end

      # Records one occurrence. Returns the group to send ({fingerprint:, count:,
      # first_seen:, last_seen:}), or nil when it is held back as a repeat.
      def record(fingerprint, now: Time.now)
        @mutex.synchronize do
          group = @groups[fingerprint]
          if group && now - group[:sent_at] < @window
            group[:held] += 1
            group[:first_held] ||= now
            next
          end

          sent = { fingerprint: fingerprint, count: 1 + (group ? group[:held] : 0),
                   first_seen: group&.dig(:first_held) || now, last_seen: now }
          @groups.delete(fingerprint)
          @groups[fingerprint] = { sent_at: now, held: 0, first_held: nil }
          @groups.shift while @groups.size > MAX_GROUPS
          sent
        end
      end

      def clear
        @mutex.synchronize { @groups.clear }
      end
    end
  end
end
