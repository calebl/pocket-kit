require "fileutils"
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
    PRUNE_GRACE_SECONDS = 600

    # Whether pages record and reports keep a replay.
    def self.enabled?
      PocketKit.replay.enabled == true
    end

    def self.viewable?(controller)
      PocketKit.replay.viewer.call(controller) ? true : false
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
      File.read(path) if File.file?(path)
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

    def self.prune(directory)
      files = Dir.glob(directory.join("*.json")).sort_by { File.mtime(_1) }
      expired = files.take_while { File.mtime(_1) <= Time.now - PRUNE_GRACE_SECONDS }
      expired.first([ files.size - PocketKit.replay.keep, 0 ].max).each { FileUtils.rm_f(_1) }
    end

    private_class_method :events?, :finite_numbers?, :prune
  end

  class Engine
    initializer "pocket_kit.replay" do |app|
      # Replays can hold what was on screen; keep them out of the log.
      app.config.filter_parameters += [ :replay ]
      ActiveSupport.on_load(:action_controller_base) { helper PocketKit::Replay::Helper }
    end
  end
end
