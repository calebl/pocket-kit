ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"

# A stand-in for the configured command: records its arguments and stdin next
# to itself and exits with $FAKE_EXIT, so a test reads exactly what left the app.
# Each file is written aside and renamed into place, so a test polling for it
# from another thread never reads it half-written.
module FakeCommand
  ENV_NAME = "DUMMY_FEEDBACK_COMMAND".freeze

  def install_fake_command
    @command_dir = Dir.mktmpdir
    @command_script = File.join(@command_dir, "fake-command")
    File.write(@command_script, <<~SH)
      #!/bin/sh
      dir="$(dirname "$0")"
      printf '%s\\n' "$@" > "$dir/args.tmp" && mv "$dir/args.tmp" "$dir/args"
      cat > "$dir/stdin.tmp" && mv "$dir/stdin.tmp" "$dir/stdin"
      exit "${FAKE_EXIT:-0}"
    SH
    File.chmod(0o755, @command_script)
    @previous_command = ENV.fetch(ENV_NAME, nil)
    ENV[ENV_NAME] = "#{@command_script} send"
  end

  def remove_fake_command
    ENV[ENV_NAME] = @previous_command
    ENV.delete("FAKE_EXIT")
    FileUtils.remove_entry(@command_dir)
  end

  def recorded(name)
    path = File.join(@command_dir, name)
    File.read(path) if File.exist?(path)
  end
end

# Saves replays to a fresh directory and puts the replay settings back after.
module ReplaySettings
  def use_replay_directory
    @replay_dir = Dir.mktmpdir
    @previous_replay = PocketKit.instance_variable_get(:@replay)
    PocketKit.instance_variable_set(:@replay, PocketKit::Replay::Configuration.new)
    PocketKit.replay.directory = @replay_dir
  end

  def restore_replay_settings
    PocketKit.instance_variable_set(:@replay, @previous_replay)
    FileUtils.remove_entry(@replay_dir)
  end
end
