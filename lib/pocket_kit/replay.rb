require "fileutils"
require "ipaddr"
require "json"
require "securerandom"
require "pocket_kit/engine"
require "pocket_kit/replay/configuration"
require "pocket_kit/replay/helper"

module PocketKit
  # The session replay piece settings, set from an initializer.
  def self.replay
    @replay ||= Replay::Configuration.new
  end

  # Session replay: the page keeps the last ~30 seconds of activity in memory
  # (recorded by the vendored rrweb) and sends it along with a feedback note or
  # a page error. The server checks it, saves it as a JSON file of rrweb
  # events, and the report names that file instead of carrying the events.
  module Replay
    RECORDER = "pocket_kit/vendor/rrweb-record-2.1.7.min.js".freeze
    PLAYER = "pocket_kit/vendor/rrweb-player-2.1.7.min.js".freeze
    PLAYER_STYLES = "pocket_kit/vendor/rrweb-player-2.1.7.css".freeze
    ID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    FULL_SNAPSHOT = 2
    MAX_NESTING = 500
    PRUNE_GRACE_SECONDS = (Errors::Outbox::MAX_QUEUED + 1) *
                            (Errors::COMMAND_TIMEOUT + Command::TERMINATION_GRACE) + 60

    # Whether pages record and reports keep a replay.
    def self.enabled?
      PocketKit.replay.enabled == true
    end

    def self.viewable?(controller)
      PocketKit.replay.viewer.call(controller) ? true : false
    end

    # Request headers a proxy uses to name the client it forwards for.
    FORWARDING_HEADERS = %w[HTTP_X_FORWARDED_FOR HTTP_X_REAL_IP HTTP_CLIENT_IP HTTP_TRUE_CLIENT_IP
                            HTTP_X_CLUSTER_CLIENT_IP HTTP_FORWARDED].freeze

    # Whether the request was made on this machine: the connection comes from
    # a loopback address and no forwarding header names any other client. A
    # local proxy such as `tailscale serve` connects from 127.0.0.1 but names
    # the real client in X-Forwarded-For, so that request is refused.
    def self.local_request?(request)
      return false unless loopback?(request.get_header("REMOTE_ADDR"))

      FORWARDING_HEADERS.all? do |name|
        value = request.get_header(name)
        next true if value.nil?

        clients = name == "HTTP_FORWARDED" ? value.to_s.scan(/for\s*=\s*("[^"]*"|[^;,\s]*)/i).flatten : value.to_s.split(",")
        clients.all? { loopback?(_1) }
      end
    end

    # Seconds a replay is kept: the configured max_age, but never less than
    # the delivery grace.
    def self.max_age
      [ PocketKit.replay.max_age.to_f, PRUNE_GRACE_SECONDS ].max
    end

    # Deletes expired replays (and those over the keep target) now, so they
    # expire even when no new report arrives. Never raises.
    def self.expire
      directory = self.directory
      prune(directory) if directory.directory?
    rescue SystemCallError, IOError
      nil
    end

    def self.directory
      Pathname(PocketKit.replay.directory || Rails.root.join("tmp/pocket_kit/replays"))
    end

    # Checks a posted replay (a JSON string of rrweb events) and saves it.
    # Returns { id:, path:, events: }, or nil when it is missing, over
    # max_bytes, not a list of rrweb events with a full snapshot, or cannot be
    # written. The report is sent either way.
    def self.store(value)
      return unless value.is_a?(String) && !value.empty? && value.bytesize <= PocketKit.replay.max_bytes

      path = nil
      events = JSON.parse(value, max_nesting: MAX_NESTING)
      return unless events?(events)

      id = SecureRandom.uuid
      directory = self.directory
      FileUtils.mkdir_p(directory, mode: 0o700)
      path = directory.join("#{id}.json")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(events, max_nesting: MAX_NESTING))
      end
      prune(directory)
      { id: id, path: path.to_s, events: events.size }
    rescue JSON::ParserError, JSON::GeneratorError, SystemCallError, IOError
      FileUtils.rm_f(path) if path
      nil
    end

    def self.complete(replay, delivered:)
      return unless replay

      path = replay[:path]
      delivered ? prune(Pathname(path).dirname) : FileUtils.rm_f(path)
    rescue SystemCallError, IOError
      nil
    end

    # Saves the replay posted to one of the engine's endpoints, when replay is
    # on. Returns what the report carries ({ path:, events:, viewer: }),
    # or nil.
    def self.from_request(controller)
      return unless enabled?

      saved = store(controller.params[:replay])
      saved && { path: saved[:path], events: saved[:events], viewer: controller.pocket_kit.replay_path(saved[:id]) }
    end

    # The saved replay's JSON, or nil.
    def self.read(id)
      return unless id.is_a?(String) && id.match?(ID_FORMAT)

      path = directory.join("#{id}.json")
      File.read(path) if File.file?(path) && !expired?(File.mtime(path))
    rescue SystemCallError, IOError
      nil
    end

    def self.expired?(mtime, now = Time.now)
      mtime <= now - max_age
    end

    def self.loopback?(value)
      address = value.to_s.strip.delete_prefix('"').delete_suffix('"')
      address = address[/\A\[([^\]]*)\]/, 1] || (address.count(":") == 1 ? address.split(":").first : address)
      IPAddr.new(address.to_s).then { _1.loopback? || (_1.ipv4_mapped? && _1.native.loopback?) }
    rescue IPAddr::Error, ArgumentError
      false
    end

    def self.events?(events)
      events.is_a?(Array) &&
        events.all? { _1.is_a?(Hash) && _1["type"].is_a?(Integer) && _1["timestamp"].is_a?(Numeric) } &&
        events.any? { _1["type"] == FULL_SNAPSHOT } && finite_numbers?(events)
    end

    def self.finite_numbers?(value)
      case value
      when Numeric then value.finite?
      when Array then value.all? { finite_numbers?(_1) }
      when Hash then value.each_value.all? { finite_numbers?(_1) }
      else true
      end
    end

    # Deletes replays older than max_age, then the oldest past the delivery
    # grace until at most `keep` remain. A replay inside the grace is never
    # deleted here.
    def self.prune(directory)
      now = Time.now
      files = Dir.glob(directory.join("*.json")).filter_map do |path|
        [ path, File.mtime(path) ]
      rescue Errno::ENOENT
        nil
      end.sort_by(&:last)
      graced = files.take_while { |_path, mtime| mtime <= now - PRUNE_GRACE_SECONDS }
      too_old, old = graced.partition { |_path, mtime| expired?(mtime, now) }
      excess = [ files.size - too_old.size - PocketKit.replay.keep, 0 ].max
      (too_old + old.first(excess)).each { |path, _mtime| FileUtils.rm_f(path) }
    end

    private_class_method :events?, :finite_numbers?, :prune, :expired?, :loopback?
  end

  class Engine
    initializer "pocket_kit.replay" do |app|
      # Replays can hold what was on screen; keep them out of the log.
      app.config.filter_parameters += [ :replay ]
      ActiveSupport.on_load(:action_controller_base) { helper PocketKit::Replay::Helper }
      # Expire old replays when the app starts, even if no report arrives.
      app.config.after_initialize { PocketKit::Replay.expire if PocketKit::Replay.enabled? }
    end
  end
end
