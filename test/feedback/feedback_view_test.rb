require "test_helper"

class FeedbackViewTest < ActionDispatch::IntegrationTest
  include FakeCommand

  setup do
    PocketKit::FeedbackController::RATE_STORE.clear
    install_fake_command
  end

  teardown { remove_fake_command }

  test "the button is shown only when a command is configured and the gate allows it" do
    get root_path
    assert_select "#pocket_kit_feedback dialog.pk-feedback-dialog"
    assert_select "#pocket_kit_feedback input[name=screen][value=?]", "pages#home"

    cookies["hide_feedback"] = "1"
    get root_path
    assert_select "#pocket_kit_feedback", count: 0

    cookies.delete("hide_feedback")
    ENV.delete(FakeCommand::ENV_NAME)
    get root_path
    assert_select "#pocket_kit_feedback", count: 0
  end

  test "extra hidden fields are rendered only when configured and given" do
    get note_path(7)
    assert_select "#pocket_kit_feedback input[name=note_id][value=?]", "7"

    get root_path
    assert_select "#pocket_kit_feedback input[name=note_id]", count: 0
  end

  # The whole round trip a click makes: the page's own form, posted as it
  # stands, answered with a stream that closes the dialog and says "Sent".
  test "the form on the page posts what the page carries" do
    get note_path(7)
    fields = css_select("#pocket_kit_feedback form input[type=hidden]").to_h { |input| [ input["name"], input["value"] ] }
    PocketKit::Feedback::DEVICE_FIELDS.each_key do |field|
      assert_select "#pocket_kit_feedback form input[name=?][data-pocket-kit--feedback-target=device][data-field=?]",
                    "device[#{field}]", field.to_s
    end
    fields["device[screen]"] = "390x844" # as the dialog's script fills it in

    post css_select("#pocket_kit_feedback form").first["action"], params: fields.merge("text" => "Add tags"),
                                                                   as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=replace][target=pocket_kit_feedback] .pk-feedback-sent", text: "Sent"
    assert_equal "Dummy feedback (screen: pages#note)\nNote: 7\n\nAdd tags\n\nDevice:\nScreen: 390x844\n",
                 recorded("stdin")
  end

  test "the stylesheet and the Stimulus controller are served to the app" do
    get root_path
    assert_select "link[rel=stylesheet][href*='pocket_kit/feedback']"
    assert_includes response.body, '"controllers/pocket_kit/feedback_controller"'

    get Rails.application.assets.resolver.resolve("pocket_kit/feedback_controller.js")
    assert_response :success
    assert_includes response.body, "describe()"
  end

  test "an app can replace the partial" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "pocket_kit/feedback"))
      File.write(File.join(dir, "pocket_kit/feedback/_feedback.html.erb"), '<div id="pocket_kit_feedback">Custom</div>')
      ApplicationController.prepend_view_path(dir)
      get root_path
      assert_select "#pocket_kit_feedback", text: "Custom"
    ensure
      ApplicationController.view_paths = ApplicationController.view_paths.to_a.reject { |path| path.to_s == dir }
    end
  end
end
