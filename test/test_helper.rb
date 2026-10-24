ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"

# A stand-in for the configured command: records its arguments and stdin next
# to itself and exits with $FAKE_EXIT, so a test reads exactly what left the app.
module FakeCommand
  ENV_NAME = "DUMMY_FEEDBACK_COMMAND".freeze

  def install_fake_command
    @command_dir = Dir.mktmpdir
    @command_script = File.join(@command_dir, "fake-command")
    File.write(@command_script, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" > "$(dirname "$0")/args"
      cat > "$(dirname "$0")/stdin"
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
