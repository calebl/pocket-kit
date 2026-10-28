require "test_helper"

class ErrorsTest < ActionDispatch::IntegrationTest
  include FakeCommand

  ERRORS_ENV = "DUMMY_ERRORS_COMMAND".freeze

  setup do
    PocketKit::ErrorsController::RATE_STORE.clear
    PocketKit::FeedbackController::RATE_STORE.clear
    PocketKit::Errors.reset!
    install_fake_command
    ENV[ERRORS_ENV] = "#{@command_script} errors"
  end

  teardown do
    PocketKit::Errors.flush
    ENV.delete(ERRORS_ENV)
    remove_fake_command
  end

  def report
    PocketKit::Errors.flush
    JSON.parse(recorded("stdin")) if recorded("stdin")
  end

  # Runs the job the way a queue adapter does.
  def run_job(id)
    assert_raises(ArgumentError) { ActiveJob::Base.execute(FailingJob.new(id).serialize) }
  end

  def post_page_error(**payload)
    post pocket_kit.errors_path, params: { kind: "error", class: "TypeError", message: "x is undefined",
                                           stack: "TypeError: x is undefined\n    at save (/assets/app.js:3:9)",
                                           page: "/notes/7", screen: "pages#note", **payload }, as: :json
  end

  test "an unhandled request exception is sent as a JSON report" do
    get broken_path(5)

    assert_response :internal_server_error
    sent = report
    assert_match(/\Aerrors\n--request-id\ndummy-errors-\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\n--json\n-\n\z/,
                 recorded("args"))
    assert_equal 1, sent["version"]
    assert_equal "error", sent["kind"]
    assert_equal "Dummy", sent["app"]
    assert_equal "request", sent["source"]
    assert_equal "NoMethodError", sent.dig("error", "class")
    assert_equal "undefined method 'title' for nil (note 5)", sent.dig("error", "message")
    assert_match %r{pages_controller\.rb}, sent.dig("error", "backtrace").first
    assert_equal 1, sent.dig("group", "count")
    assert sent["text"].start_with?("Dummy error (source: request)\n\nNoMethodError: undefined method"), sent["text"]
  end

  test "repeats with the same fingerprint are counted, not sent, until the group window passes" do
    get broken_path(1)
    first = report
    File.delete(File.join(@command_dir, "stdin"))

    get broken_path(2)
    get broken_path(3)
    assert_nil report, "a repeat inside the window runs no command"

    travel PocketKit.errors.group_window + 1 do
      get broken_path(4)
      later = report
      assert_equal first.dig("group", "fingerprint"), later.dig("group", "fingerprint")
      assert_equal 3, later.dig("group", "count")
      assert_includes later["text"], "Seen 3 times since"
    end
  end

  test "an Active Job exception is sent with the job's class" do
    run_job(9)

    sent = report
    assert_equal "job", sent["source"]
    assert_equal "Bad record 9", sent.dig("error", "message")
    assert_equal [ "Job: FailingJob" ], sent["context"]
  end

  test "an error the app handles and reports itself is not sent" do
    Rails.error.handle { raise "handled" }

    assert_nil report
  end

  test "requests and jobs can be turned off separately" do
    PocketKit.errors.requests = false
    PocketKit.errors.jobs = false
    get broken_path(1)
    run_job(1)

    assert_nil report
  ensure
    PocketKit.errors.requests = true
    PocketKit.errors.jobs = true
  end

  test "nothing is sent and the endpoint is not found when no command is configured" do
    ENV.delete(ERRORS_ENV)
    get broken_path(1)
    post_page_error

    assert_response :not_found
    assert_nil report
  end

  test "an error from the page is checked and sent as a browser report" do
    post_page_error

    assert_response :accepted
    sent = report
    assert_equal "browser", sent["source"]
    assert_equal "pages#note", sent["screen"]
    assert_equal "/notes/7", sent["page"]
    assert_equal "TypeError", sent.dig("error", "class")
    assert_equal [ "TypeError: x is undefined", "at save (/assets/app.js:3:9)" ], sent.dig("error", "backtrace")
  end

  test "page fields that do not pass their checks are dropped or replaced" do
    post_page_error(class: "Bad class\n", message: "boom\u0007", screen: "pages#secret", page: "https://elsewhere/")

    assert_response :accepted
    sent = report
    assert_equal "Error", sent.dig("error", "class")
    assert_equal "boom", sent.dig("error", "message")
    assert_nil sent["screen"]
    assert_nil sent["page"]
  end

  test "a page error without a message is refused" do
    post_page_error(message: " ")

    assert_response :unprocessable_content
    assert_nil report
  end

  test "page errors are rate limited" do
    PocketKit::ErrorsController::ERRORS_PER_MINUTE.times { |i| post_page_error(message: "error #{i}") }
    post_page_error

    assert_response :too_many_requests
  end

  test "the layout tag names the endpoint only while the piece is on" do
    get root_path
    assert_select "meta[name=pocket-kit-errors][content=?]", pocket_kit.errors_path
    assert_select "meta[name=pocket-kit-screen][content=?]", "pages#home"

    ENV.delete(ERRORS_ENV)
    get root_path
    assert_select "meta[name=pocket-kit-errors]", count: 0
  end

  test "feedback can be sent as the same JSON report" do
    PocketKit.feedback.format = :json
    post pocket_kit.feedback_path, params: { text: "Tags please", screen: "pages#home",
                                             request_id: "0b6f1c1e-6a51-4d6a-9d3e-3f3a0c2e9b11",
                                             device: { pixel_ratio: "3" } }, as: :turbo_stream

    assert_response :success
    sent = JSON.parse(recorded("stdin"))
    assert_equal [ 1, "feedback", "Dummy feedback", "browser", "pages#home", "Tags please" ],
                 sent.values_at("version", "kind", "app", "source", "screen", "note")
    assert_equal({ "pixel_ratio" => "3" }, sent["device"])
    assert_equal "Dummy feedback (screen: pages#home)\n\nTags please\n\nDevice:\nPixel ratio: 3\n", sent["text"]
  ensure
    PocketKit.feedback.format = :text
  end
end
