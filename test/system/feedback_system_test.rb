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

  test "standalone feedback keeps its request id across retries and blocks overlapping sends" do
    visit root_path
    execute_script(<<~JS)
      window.feedbackRequests = []
      window.feedbackResolvers = []
      window.fetch = (_url, options) => {
        window.feedbackRequests.push(JSON.parse(options.body))
        return new Promise((resolve) => window.feedbackResolvers.push(resolve))
      }
      const root = document.createElement("div")
      root.id = "standalone-feedback"
      root.dataset.pkFeedback = "/report"
      root.innerHTML = `
        <span data-pk-sent hidden>Sent</span>
        <dialog><form>
          <textarea name="text"></textarea>
          <p data-pk-failed hidden>Failed</p>
        </form></dialog>`
      document.body.append(root)
      window.PocketKit.feedback(root)
      root.querySelector("textarea").value = "Retry me"
      window.submitStandaloneFeedback = () => root.querySelector("form").dispatchEvent(
        new Event("submit", { bubbles: true, cancelable: true })
      )
    JS

    2.times { execute_script("window.submitStandaloneFeedback()") }
    assert_equal 1, evaluate_script("window.feedbackRequests.length")
    first_id = evaluate_script("window.feedbackRequests[0].request_id")

    execute_script("window.feedbackResolvers.shift()({ ok: false })")
    assert_equal false, evaluate_script("document.querySelector('#standalone-feedback [data-pk-failed]').hidden")
    execute_script("window.submitStandaloneFeedback()")
    assert_equal first_id, evaluate_script("window.feedbackRequests[1].request_id")

    execute_script("window.feedbackResolvers.shift()({ ok: true })")
    assert_selector "#standalone-feedback [data-pk-sent]:not([hidden])"
    execute_script("document.querySelector('#standalone-feedback textarea').value = 'Another note'; " \
                   "window.submitStandaloneFeedback()")
    assert_not_equal first_id, evaluate_script("window.feedbackRequests[2].request_id")
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
