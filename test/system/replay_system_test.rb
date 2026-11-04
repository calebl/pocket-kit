require "test_helper"
require "capybara/rails"

class ReplaySystemTest < ActionDispatch::SystemTestCase
  include FakeCommand
  include ReplaySettings

  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ]

  setup do
    PocketKit::FeedbackController::RATE_STORE.clear
    PocketKit::ErrorsController::RATE_STORE.clear
    PocketKit::Errors.reset!
    install_fake_command
    use_replay_directory
  end

  teardown do
    PocketKit::Errors.flush
    ENV.delete("DUMMY_ERRORS_COMMAND")
    remove_fake_command
    restore_replay_settings
  end

  def wait_for_recording
    Timeout.timeout(5) { sleep 0.05 until evaluate_script("window.PocketKit.replayEvents() !== null") }
  end

  def send_feedback(text)
    find("button[aria-label='Send feedback']").click
    within "dialog.pk-feedback-dialog[open]" do
      fill_in "pocket_kit_feedback_text", with: text
      click_on "Send"
    end
    assert_selector ".pk-feedback-sent", text: "Sent"
  end

  def saved_replay
    path = recorded("stdin")[/^Replay: (.+)$/, 1]
    assert path, recorded("stdin")
    File.read(path)
  end

  test "with replay off, no recorder loads and a note carries no replay" do
    visit note_path(7)
    assert_no_selector "meta[name='pocket-kit-replay']", visible: :all
    assert_nil evaluate_script("window.PocketKit.replayEvents()")
    assert_equal false, evaluate_script("'rrwebRecord' in window")
    assert_no_selector "input[name='replay']", visible: :all

    send_feedback("Notes could use tags")
    assert_not_includes recorded("stdin"), "Replay:"
    assert_empty Dir.glob(File.join(@replay_dir, "*"))
  end

  test "a note carries the recent page activity, with typed text masked by default" do
    PocketKit.replay.enabled = true
    visit note_path(7)
    wait_for_recording
    find("[data-replay-editor]").set("Edited private draft")

    send_feedback("My private draft")
    events = JSON.parse(saved_replay)
    replay_json = JSON.generate(events)
    assert events.any? { _1["type"] == 2 }, "has a full snapshot"
    assert_not_includes replay_json, "Existing private draft"
    assert_not_includes replay_json, "Edited private draft"
    assert_not_includes replay_json, "My private draft"
    assert events.any? { |event| event.dig("data", "text").to_s.match?(/\A\*+\z/) }, "typed text is masked"
  end

  test "showing typed text is a setting" do
    PocketKit.replay.enabled = true
    PocketKit.replay.show_typed_text = true
    visit note_path(7)
    wait_for_recording
    find("[data-replay-editor]").set("Edited visible draft")

    send_feedback("Visible words")
    replay_json = saved_replay
    assert_includes replay_json, "Existing private draft"
    assert_includes replay_json, "Edited visible draft"
    assert_includes replay_json, "Visible words"
  end

  test "a page error carries the recent page activity" do
    PocketKit.replay.enabled = true
    ENV["DUMMY_ERRORS_COMMAND"] = "#{@command_script} errors"
    visit note_path(7)
    wait_for_recording
    execute_script("const script = document.createElement('script'); " \
                   "script.textContent = \"setTimeout(() => { throw new TypeError('boom') })\"; " \
                   "document.body.append(script)")

    Timeout.timeout(5) do
      until recorded("stdin")
        PocketKit::Errors.flush
        sleep 0.05
      end
    end
    report = JSON.parse(recorded("stdin"))
    assert_equal "boom", report.dig("error", "message")
    assert JSON.parse(File.read(report.dig("replay", "path"))).any? { _1["type"] == 2 }
    assert_match %r{\A/pocket-kit/replays/\h{8}-}, report.dig("replay", "viewer")
  end

  test "the buffer keeps about the last 30 seconds in whole segments, within the size cap" do
    visit root_path
    kept = evaluate_script(<<~JS)
      (() => {
        const buffer = new window.PocketKit.ReplayBuffer(30000)
        const segment = (at) => [ { type: 4, timestamp: at }, { type: 2, timestamp: at }, { type: 3, timestamp: at + 5000 } ]
        ;[ 0, 10000, 20000 ].forEach((at) => segment(at).forEach((event) => buffer.add(event)))
        buffer.add({ type: 3, timestamp: 41000 })
        const firsts = (json) => json && JSON.parse(json).filter((event) => event.type === 4).map((event) => event.timestamp)
        const all = buffer.serialize(1000000, 41000)
        const small = buffer.serialize(new TextEncoder().encode(JSON.stringify(buffer.segments.at(-1))).length, 41000)
        return { all: firsts(all), small: firsts(small), none: buffer.serialize(10, 41000) }
      })()
    JS

    assert_equal [ 10000, 20000 ], kept["all"]
    assert_equal [ 20000 ], kept["small"]
    assert_nil kept["none"]
  end

  test "a replay over the size cap is left out and the note is still sent" do
    PocketKit.replay.enabled = true
    PocketKit.replay.max_bytes = 10
    visit note_path(7)
    assert_selector "meta[name='pocket-kit-replay'][data-max-bytes='10']", visible: :all
    sleep 0.5

    send_feedback("Still sent")
    assert_includes recorded("stdin"), "Still sent"
    assert_not_includes recorded("stdin"), "Replay:"
  end

  test "the viewer plays a saved replay" do
    PocketKit.replay.enabled = true
    visit note_path(7)
    wait_for_recording
    send_feedback("Watch this")
    id = File.basename(recorded("stdin")[/^Replay: (.+)$/, 1], ".json")

    visit pocket_kit.replay_path(id)
    assert_selector "[data-pk-replay-loaded]"
    assert_selector ".rr-player iframe", visible: :all
  end

  test "the static viewer opens a replay file from this computer" do
    PocketKit.replay.enabled = true
    visit note_path(7)
    wait_for_recording
    send_feedback("Pick me")
    path = recorded("stdin")[/^Replay: (.+)$/, 1]

    page.driver.browser.navigate.to("file://#{File.expand_path('../../viewer/replay.html', __dir__)}")
    find("input[data-pk-replay-file]").attach_file(path)
    assert_selector "[data-pk-replay-loaded]"
    assert_selector ".rr-player iframe", visible: :all
  end
end
