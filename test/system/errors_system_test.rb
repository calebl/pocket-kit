require "test_helper"
require "capybara/rails"

class ErrorsSystemTest < ActionDispatch::SystemTestCase
  include FakeCommand

  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ]

  setup do
    PocketKit::ErrorsController::RATE_STORE.clear
    PocketKit::Errors.reset!
    install_fake_command
    ENV["DUMMY_ERRORS_COMMAND"] = "#{@command_script} errors"
  end

  teardown do
    PocketKit::Errors.flush
    ENV.delete("DUMMY_ERRORS_COMMAND")
    remove_fake_command
  end

  # Runs code as one of the page's own scripts; errors in code run by the
  # driver itself reach the page without their details.
  def run_on_page(code)
    execute_script("const script = document.createElement('script'); script.textContent = arguments[0]; " \
                   "document.body.append(script)", code)
  end

  def wait_for_report
    Timeout.timeout(5) do
      until recorded("stdin")
        PocketKit::Errors.flush
        sleep 0.05
      end
    end
    JSON.parse(recorded("stdin"))
  end

  test "an uncaught error on the page is sent with its screen and page" do
    visit note_path(7)
    assert_selector "h1", text: "Note 7"
    run_on_page("setTimeout(() => { throw new TypeError('note.title is undefined') })")

    sent = wait_for_report
    assert_equal [ "browser", "pages#note", "/notes/7" ], sent.values_at("source", "screen", "page")
    assert_equal [ "TypeError", "note.title is undefined" ], sent["error"].values_at("class", "message")
  end

  test "an unhandled promise rejection is sent" do
    visit root_path
    assert_selector "h1", text: "Home"
    run_on_page("Promise.reject(new RangeError('page out of range'))")

    sent = wait_for_report
    assert_equal [ "RangeError", "page out of range" ], sent["error"].values_at("class", "message")
  end
end
