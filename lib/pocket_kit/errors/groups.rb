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
    # At most MAX_GROUPS completed fingerprints are remembered; the least
    # recently sent is forgotten first.
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
          if group && (group[:attempt] || (group[:sent_at] && now - group[:sent_at] < @window))
            group[:held] += 1
            group[:first_held] ||= now
            next
          end

          sent = { fingerprint: fingerprint, count: 1 + (group ? group[:held] : 0),
                   first_seen: group&.dig(:first_held) || now, last_seen: now }
          @groups.delete(fingerprint)
          @groups[fingerprint] = { sent_at: nil, held: 0, first_held: nil, attempt: sent }
          evict_completed
          sent
        end
      end

      def commit(group, now: Time.now)
        @mutex.synchronize do
          current = @groups[group[:fingerprint]]
          return unless current&.dig(:attempt).equal?(group)

          current[:sent_at] = now
          current[:attempt] = nil
          evict_completed
        end
      end

      def rollback(group)
        @mutex.synchronize do
          current = @groups[group[:fingerprint]]
          return unless current&.dig(:attempt).equal?(group)

          current[:sent_at] = nil
          current[:held] += group[:count]
          current[:first_held] = group[:first_seen]
          current[:attempt] = nil
        end
      end

      def clear
        @mutex.synchronize { @groups.clear }
      end

      private

      def evict_completed
        while @groups.size > MAX_GROUPS
          fingerprint, = @groups.find { |_key, group| group[:sent_at] }
          break unless fingerprint

          @groups.delete(fingerprint)
        end
      end
    end
  end
end
