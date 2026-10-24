require "test_helper"

class FeedbackControllerTest < ActionDispatch::IntegrationTest
  include FakeCommand

  REQUEST_ID = "0b6f1c1e-6a51-4d6a-9d3e-3f3a0c2e9b11".freeze

  setup do
    PocketKit::FeedbackController::RATE_STORE.clear
    install_fake_command
  end

  teardown { remove_fake_command }

  def send_note(text: "The save button is hard to find", screen: "pages#home", request_id: REQUEST_ID, **extra)
    post pocket_kit.feedback_path, params: { text: text, screen: screen, request_id: request_id, **extra },
                                   as: :turbo_stream
  end

  test "runs the command with the request id as arguments and the note on stdin" do
    send_note

    assert_response :success
    assert_select "turbo-stream[action=replace][target=pocket_kit_feedback] .pk-feedback-sent", text: "Sent"
    assert_equal "send\n--request-id\ndummy-feedback-#{REQUEST_ID}\n--json\n-\n", recorded("args")
    assert_equal "Dummy feedback (screen: pages#home)\n\nThe save button is hard to find\n", recorded("stdin")
  end

  test "the app's context lines go under the heading" do
    send_note(screen: "pages#note", note_id: "42")

    assert_equal "Dummy feedback (screen: pages#note)\nNote: 42\n\nThe save button is hard to find\n",
                 recorded("stdin")
    assert_select "turbo-stream #pocket_kit_feedback input[name=note_id][value=?]", "42"
  end

  test "what the browser reports about the device follows the note as a Device block" do
    send_note(device: { user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", screen: "390x844",
                        viewport: "390x664", visual_viewport: "390x400", pixel_ratio: "3",
                        standalone: "true", color_scheme: "dark" })

    assert_equal "Dummy feedback (screen: pages#home)\n\nThe save button is hard to find\n\n" \
                 "Device:\nBrowser: Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)\nScreen: 390x844\n" \
                 "Viewport: 390x664\nVisual viewport: 390x400\nPixel ratio: 3\nHome screen app: true\n" \
                 "Color scheme: dark\n", recorded("stdin")
  end

  test "a device value that is malformed, overlong or unknown is dropped, and the note is still sent" do
    send_note(device: { user_agent: "a" * 301, screen: "390x844\nNote: forged", viewport: "wide",
                        visual_viewport: "390x400; rm", pixel_ratio: "2.5", standalone: "maybe",
                        color_scheme: "sepia", token: "secret" })

    assert_response :success
    assert_equal "Dummy feedback (screen: pages#home)\n\nThe save button is hard to find\n\n" \
                 "Device:\nPixel ratio: 2.5\n", recorded("stdin")
  end

  test "a user agent with control characters is dropped" do
    send_note(device: { user_agent: "Evil\nInjected: yes" })

    assert_equal "Dummy feedback (screen: pages#home)\n\nThe save button is hard to find\n", recorded("stdin")
  end

  test "a device param that is not a set of fields is ignored" do
    send_note(device: "390x844")

    assert_response :success
    assert_equal "Dummy feedback (screen: pages#home)\n\nThe save button is hard to find\n", recorded("stdin")
  end

  test "shell metacharacters in the variable stay literal arguments" do
    marker = File.join(@command_dir, "SHELL_RAN")
    ENV[FakeCommand::ENV_NAME] = "#{@command_script} ';' touch #{marker}"
    send_note

    assert_response :success
    assert_equal ";\ntouch\n#{marker}\n--request-id\ndummy-feedback-#{REQUEST_ID}\n--json\n-\n", recorded("args")
    assert_not File.exist?(marker)
  end

  test "exit code 3 counts as sent by default" do
    ENV["FAKE_EXIT"] = "3"
    send_note

    assert_response :success
    assert_includes response.body, "Sent"
  end

  test "sent exit codes are configurable" do
    ENV["FAKE_EXIT"] = "3"
    previous = PocketKit.feedback.sent_exit_codes
    PocketKit.feedback.sent_exit_codes = [ 0 ]
    send_note

    assert_response :unprocessable_content
  ensure
    PocketKit.feedback.sent_exit_codes = previous
  end

  test "a failing command is reported inside the dialog, not as sent" do
    ENV["FAKE_EXIT"] = "1"
    send_note

    assert_response :unprocessable_content
    assert_select "turbo-stream[action=replace][target=pocket_kit_feedback_status] .pk-feedback-failed",
                  text: "Couldn't send. Your note is still here."
    assert_not_includes response.body, "Sent"
  end

  test "a missing command is reported as a failure" do
    ENV[FakeCommand::ENV_NAME] = File.join(@command_dir, "missing")
    send_note

    assert_response :unprocessable_content
  end

  test "a command that exceeds the timeout has its process group killed and is reported as a failure" do
    script = File.join(@command_dir, "hanging-command")
    child_script = File.join(@command_dir, "hanging-child")
    pid_file = File.join(@command_dir, "pid")
    child_pid_file = File.join(@command_dir, "child-pid")
    child_stopped_file = File.join(@command_dir, "child-stopped")
    File.write(child_script, <<~RUBY)
      trap("TERM") do
        File.write(#{child_stopped_file.dump}, "stopped")
        exit!
      end
      File.write(#{child_pid_file.dump}, Process.pid.to_s)
      sleep
    RUBY
    File.write(script, <<~RUBY)
      #!/usr/bin/env ruby
      trap("TERM") {}
      File.write(#{pid_file.dump}, Process.pid.to_s)
      child = spawn(#{RbConfig.ruby.dump}, #{child_script.dump})
      Process.wait(child)
      sleep
    RUBY
    File.chmod(0o755, script)
    ENV[FakeCommand::ENV_NAME] = script
    controller = PocketKit::FeedbackController
    original_timeout = controller::COMMAND_TIMEOUT
    controller.send(:remove_const, :COMMAND_TIMEOUT)
    controller.const_set(:COMMAND_TIMEOUT, 0.5)

    send_note

    assert_response :unprocessable_content
    assert_equal "stopped", File.read(child_stopped_file)
    assert_raises(Errno::ESRCH) { Process.kill(0, File.read(pid_file).to_i) }
    assert_raises(Errno::ESRCH) { Process.kill(0, File.read(child_pid_file).to_i) }
  ensure
    if original_timeout
      controller.send(:remove_const, :COMMAND_TIMEOUT)
      controller.const_set(:COMMAND_TIMEOUT, original_timeout)
    end
  end

  test "is not found when no command is configured" do
    ENV.delete(FakeCommand::ENV_NAME)
    send_note

    assert_response :not_found
    assert_nil recorded("stdin")
  end

  test "is not found when the app's gate says no" do
    cookies["hide_feedback"] = "1"
    send_note

    assert_response :not_found
    assert_nil recorded("stdin")
  end

  test "rejects an empty note and one over the length cap" do
    send_note(text: "   ")
    assert_response :unprocessable_content

    send_note(text: "a" * (PocketKit::FeedbackController::MAX_LENGTH + 1))
    assert_response :unprocessable_content
    assert_nil recorded("stdin")
  end

  test "rejects an unknown screen and a malformed request id" do
    send_note(screen: "pages#secret")
    assert_response :unprocessable_content

    send_note(request_id: "not-a-uuid")
    assert_response :unprocessable_content
    assert_nil recorded("stdin")
  end

  test "more than five notes in a minute are refused" do
    PocketKit::FeedbackController::NOTES_PER_MINUTE.times { send_note }
    File.delete(File.join(@command_dir, "stdin"))

    send_note
    assert_response :unprocessable_content
    assert_nil recorded("stdin")
  end
end
