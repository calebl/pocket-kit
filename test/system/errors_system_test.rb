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

  def report_on_page(message)
    page.driver.browser.execute_async_script(<<~JS, message)
      const done = arguments[arguments.length - 1]
      window.PocketKit.reportError(new Error(arguments[0])).then(done)
    JS
  end

  def rejecting_outbox
    Object.new.tap { |outbox| outbox.define_singleton_method(:push) { |&_delivery| false } }
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

  test "a failed browser post can be retried" do
    visit root_path
    original_outbox = PocketKit::Errors.instance_variable_get(:@outbox)
    PocketKit::Errors.instance_variable_set(:@outbox, rejecting_outbox)
    assert_equal false, report_on_page("retry me")
    PocketKit::Errors.instance_variable_set(:@outbox, original_outbox)

    assert_equal true, report_on_page("retry me")
    assert_equal "retry me", wait_for_report.dig("error", "message")
    assert_equal false, report_on_page("retry me")
  ensure
    PocketKit::Errors.instance_variable_set(:@outbox, original_outbox) if defined?(original_outbox)
  end

  test "failed browser posts still count toward the per-page attempt limit" do
    visit root_path
    original_outbox = PocketKit::Errors.instance_variable_get(:@outbox)
    PocketKit::Errors.instance_variable_set(:@outbox, rejecting_outbox)
    10.times { |i| assert_equal false, report_on_page("failure #{i}") }
    PocketKit::Errors.instance_variable_set(:@outbox, original_outbox)

    assert_equal false, report_on_page("one too many")
    assert_nil recorded("stdin")

    execute_script("document.dispatchEvent(new Event('turbo:load'))")
    assert_equal true, report_on_page("after navigation")
    assert_equal "after navigation", wait_for_report.dig("error", "message")
  ensure
    PocketKit::Errors.instance_variable_set(:@outbox, original_outbox) if defined?(original_outbox)
  end

  test "an old page's pending report cannot contaminate the new page" do
    visit root_path
    execute_script(<<~JS)
      window.errorRequests = []
      window.errorResolvers = []
      window.fetch = (_url, options) => {
        window.errorRequests.push(JSON.parse(options.body))
        return new Promise((resolve) => window.errorResolvers.push(resolve))
      }
      window.navigationError = new Error("navigation error")
      window.PocketKit.reportError(window.navigationError)
      document.dispatchEvent(new Event("turbo:load"))
      window.PocketKit.reportError(window.navigationError)
    JS
    assert_equal 2, evaluate_script("window.errorRequests.length")

    execute_script("window.errorResolvers.shift()({ ok: true })")
    execute_script("window.errorResolvers.shift()({ ok: false })")
    execute_script("window.PocketKit.reportError(window.navigationError)")

    assert_equal 3, evaluate_script("window.errorRequests.length")
  end

  test "a non-Error thrown value is classified as an uncaught error" do
    visit root_path
    run_on_page("setTimeout(() => { throw 'plain boom' })")

    sent = wait_for_report
    assert_equal [ "Error", "plain boom" ], sent["error"].values_at("class", "message")
  end

  test "a non-Error promise rejection is classified as an unhandled rejection" do
    visit root_path
    run_on_page("Promise.reject('plain rejection')")

    sent = wait_for_report
    assert_equal [ "UnhandledRejection", "plain rejection" ], sent["error"].values_at("class", "message")
  end

  test "an unhandled promise rejection is sent" do
    visit root_path
    assert_selector "h1", text: "Home"
    run_on_page("Promise.reject(new RangeError('page out of range'))")

    sent = wait_for_report
    assert_equal [ "RangeError", "page out of range" ], sent["error"].values_at("class", "message")
  end
end
