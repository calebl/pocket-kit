require "test_helper"
require "capybara/rails"

class FeedbackSystemTest < ActionDispatch::SystemTestCase
  include FakeCommand

  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ]

  setup do
    PocketKit::FeedbackController::RATE_STORE.clear
    install_fake_command
  end

  teardown { remove_fake_command }

  test "sending feedback from the button" do
    visit note_path(7)
    assert_no_selector "dialog.pk-feedback-dialog[open]"

    find("button[aria-label='Send feedback']").click
    within "dialog.pk-feedback-dialog[open]" do
      fill_in "pocket_kit_feedback_text", with: "Notes could use tags"
      @device = page.evaluate_script(<<~JS)
        ({
          userAgent: navigator.userAgent,
          viewport: `${window.innerWidth}x${window.innerHeight}`,
          pixelRatio: String(window.devicePixelRatio)
        })
      JS
      click_on "Send"
    end

    assert_selector ".pk-feedback-sent", text: "Sent"
    assert_no_selector "dialog.pk-feedback-dialog[open]"
    stdin = recorded("stdin")
    assert stdin.start_with?("Dummy feedback (screen: pages#note)\nNote: 7\n\nNotes could use tags\n\nDevice:\n" \
                             "Browser: #{@device['userAgent']}\n"), stdin
    assert_includes stdin, "Viewport: #{@device['viewport']}\n"
    assert_includes stdin, "Pixel ratio: #{@device['pixelRatio']}\n"
    assert_includes stdin, "Home screen app: false\n"
  end

  test "a failed send keeps the dialog open with the text in it" do
    ENV["FAKE_EXIT"] = "1"
    visit root_path

    find("button[aria-label='Send feedback']").click
    within "dialog.pk-feedback-dialog[open]" do
      fill_in "pocket_kit_feedback_text", with: "Keep this"
      click_on "Send"
      assert_selector ".pk-feedback-failed", text: "Couldn't send"
      assert_field "pocket_kit_feedback_text", with: "Keep this"
    end
  end
end
