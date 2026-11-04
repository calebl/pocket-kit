require "test_helper"

class ReplayTest < ActionDispatch::IntegrationTest
  include FakeCommand
  include ReplaySettings

  REQUEST_ID = "0b6f1c1e-6a51-4d6a-9d3e-3f3a0c2e9b11".freeze
  EVENTS = [
    { type: 4, timestamp: 1000, data: { href: "http://localhost/", width: 390, height: 844 } },
    { type: 2, timestamp: 1001, data: { node: { type: 0, childNodes: [], id: 1 }, initialOffset: { left: 0, top: 0 } } },
    { type: 3, timestamp: 1500, data: { source: 5, text: "*****", isChecked: false, id: 9 } }
  ].freeze

  setup do
    PocketKit::FeedbackController::RATE_STORE.clear
    PocketKit::ErrorsController::RATE_STORE.clear
    PocketKit::Errors.reset!
    install_fake_command
    use_replay_directory
    PocketKit.replay.enabled = true
  end

  teardown do
    PocketKit::Errors.flush
    ENV.delete("DUMMY_ERRORS_COMMAND")
    remove_fake_command
    restore_replay_settings
    PocketKit.feedback.format = :text
  end

  def send_note(replay: JSON.generate(EVENTS))
    post pocket_kit.feedback_path, params: { text: "Look", screen: "pages#home", request_id: REQUEST_ID,
                                             replay: replay }, as: :turbo_stream
  end

  def post_error(replay: JSON.generate(EVENTS))
    ENV["DUMMY_ERRORS_COMMAND"] = "#{@command_script} errors"
    post pocket_kit.errors_path, params: { kind: "error", class: "TypeError", message: "boom",
                                           stack: "at x (/a.js:1:2)", replay: replay }, as: :json
    PocketKit::Errors.flush
  end

  def saved_files
    Dir.glob(File.join(@replay_dir, "*.json"))
  end

  test "a note's replay is saved as its own file and named in the report" do
    PocketKit.feedback.format = :json
    send_note

    assert_response :success
    report = JSON.parse(recorded("stdin"))
    assert_equal [ report.dig("replay", "path") ], saved_files
    assert_equal 3, report.dig("replay", "events")
    assert_equal "/pocket-kit/replays/#{File.basename(saved_files.first, '.json')}", report.dig("replay", "viewer")
    assert_equal JSON.parse(JSON.generate(EVENTS)), JSON.parse(File.read(saved_files.first))
    assert_includes report["text"], "\nReplay: #{saved_files.first}\n"
    assert_equal "600", format("%o", File.stat(saved_files.first).mode & 0o777)
  end

  test "the text format names the replay file under the note" do
    send_note

    assert_equal "Dummy feedback (screen: pages#home)\n\nLook\n\nReplay: #{saved_files.first}\n", recorded("stdin")
  end

  test "a page error's replay is saved and named in the report" do
    post_error

    report = JSON.parse(recorded("stdin"))
    assert_equal [ report.dig("replay", "path") ], saved_files
    assert report["text"].end_with?("\nReplay: #{saved_files.first}\n")
  end

  test "a failed feedback delivery deletes its replay" do
    ENV["FAKE_EXIT"] = "1"
    send_note

    assert_response :unprocessable_content
    assert_empty saved_files
  end

  test "a failed error delivery deletes its replay" do
    ENV["FAKE_EXIT"] = "1"
    post_error

    assert_empty saved_files
  end

  test "an error rejected by the outbox deletes its replay" do
    rejecting_outbox = Object.new
    def rejecting_outbox.push
      false
    end

    ENV["DUMMY_ERRORS_COMMAND"] = "#{@command_script} errors"
    previous_outbox = PocketKit::Errors.instance_variable_get(:@outbox)
    PocketKit::Errors.instance_variable_set(:@outbox, rejecting_outbox)
    post pocket_kit.errors_path, params: { kind: "error", class: "TypeError", message: "queue full",
                                           stack: "at x (/a.js:1:2)", replay: JSON.generate(EVENTS) }, as: :json

    assert_response :service_unavailable
    assert_empty saved_files
  ensure
    PocketKit::Errors.instance_variable_set(:@outbox, previous_outbox)
  end

  test "a repeat error held back by grouping saves no replay" do
    post_error
    File.delete(File.join(@command_dir, "stdin"))
    post_error

    assert_nil recorded("stdin")
    assert_equal 1, saved_files.size
  end

  test "with replay off, a posted replay is ignored and the report is as before" do
    PocketKit.replay.enabled = false
    PocketKit.feedback.format = :json
    send_note

    assert_response :success
    assert_not JSON.parse(recorded("stdin")).key?("replay")
    assert_empty saved_files
  end

  test "a replay over the size cap is left out and the note is still sent" do
    PocketKit.replay.max_bytes = JSON.generate(EVENTS).bytesize - 1
    send_note

    assert_response :success
    assert_includes recorded("stdin"), "Look"
    assert_not_includes recorded("stdin"), "Replay:"
    assert_empty saved_files
  end

  test "a malformed or snapshot-less replay is left out and the note is still sent" do
    [ "not json", JSON.generate([ { type: 3, timestamp: 1 } ]), JSON.generate({ a: 1 }),
      JSON.generate([ { type: "2", timestamp: 1 } ]), "#{'[' * 1000}#{']' * 1000}" ].each do |replay|
      PocketKit::FeedbackController::RATE_STORE.clear
      send_note(replay: replay)
      assert_response :success
      assert_not_includes recorded("stdin"), "Replay:"
    end
    assert_empty saved_files
  end

  test "a pruning failure removes the unreferenced replay" do
    original_prune = PocketKit::Replay.method(:prune)
    PocketKit::Replay.define_singleton_method(:prune) { |_directory| raise Errno::EACCES }
    send_note

    assert_response :success
    assert_not_includes recorded("stdin"), "Replay:"
    assert_empty saved_files
  ensure
    PocketKit::Replay.define_singleton_method(:prune, original_prune)
    PocketKit::Replay.private_class_method(:prune)
  end

  test "an unwritable replay directory leaves the replay out and still sends the note" do
    PocketKit.replay.directory = File.join(@command_dir, "args-file-not-dir", "x")
    File.write(File.join(@command_dir, "args-file-not-dir"), "")
    send_note

    assert_response :success
    assert_not_includes recorded("stdin"), "Replay:"
  end

  test "only the newest replays are kept" do
    PocketKit.replay.keep = 2
    3.times do |i|
      PocketKit::FeedbackController::RATE_STORE.clear
      send_note
      FileUtils.touch(saved_files, mtime: Time.now - (10 - i)) if i < 2
    end

    assert_equal 2, saved_files.size
  end

  test "the replay is kept out of the log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("replay" => "[]")["replay"]
  end

  test "there is no app replay file picker" do
    get "/pocket-kit/replays"

    assert_response :not_found
  end

  test "the viewer serves a saved replay as JSON and a player page" do
    send_note
    id = File.basename(saved_files.first, ".json")

    get pocket_kit.replay_path(id, format: :json)
    assert_response :success
    assert_equal 3, response.parsed_body.size

    get pocket_kit.replay_path(id)
    assert_response :success
    assert_select "[data-pk-replay-viewer][data-pk-replay-src=?]", pocket_kit.replay_path(id, format: :json)
    assert_select "script[src*='rrweb-player-2.1.7']"

    get pocket_kit.replay_path(SecureRandom.uuid)
    assert_response :not_found
  end

  test "the viewer is not found when its gate says no" do
    send_note
    PocketKit.replay.viewer = ->(_controller) { false }

    get pocket_kit.replay_path(File.basename(saved_files.first, ".json"), format: :json)
    assert_response :not_found
  end

  test "the page's tag names the recorder and the masking setting only when replay is on" do
    get root_path
    assert_select "meta[name=pocket-kit-replay][data-show-typed-text=false][data-max-bytes=1000000]" do |meta|
      assert_match %r{/assets/pocket_kit/vendor/rrweb-record-2\.1\.7\.min-\w+\.js\z}, meta.first["content"]
    end
    assert_select "input[name=replay]"

    PocketKit.replay.show_typed_text = true
    get root_path
    assert_select "meta[name=pocket-kit-replay][data-show-typed-text=true]"

    PocketKit.replay.enabled = false
    get root_path
    assert_select "meta[name=pocket-kit-replay]", count: 0
    assert_select "input[name=replay]", count: 0
  end
end
