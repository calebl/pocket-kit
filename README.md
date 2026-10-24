# pocket-kit

Small shared pieces for self-hosted phone web apps: apps that run on your own
machine and that you reach from your phone over a VPN such as Tailscale.

pocket-kit is a Ruby gem and a Rails engine. Each piece is separate and
optional. Today it has:

- **Feedback button**: a small button that opens a dialog; the note typed into
  it goes to a local command you choose, along with the screen it was sent from
  and what the device reports about itself.

Coming next: pinning the header to the iPhone's visible viewport.

The repo also documents the pattern these apps follow (localhost only, the
VPN's https address in front, a start script and service, settings outside the
repo, a home-screen icon, and a deploy checklist): see
[docs/local-app-pattern.md](docs/local-app-pattern.md) and the
[templates](templates/).

## Install

```ruby
# Gemfile
gem "pocket_kit", github: "calebl/pocket-kit", tag: "v0.1.0"
```

```ruby
# config/routes.rb
mount PocketKit::Engine, at: "/pocket-kit"
```

pocket-kit needs Rails 8, turbo-rails, importmap-rails, and stimulus-rails.
The JavaScript is a Stimulus controller served through importmap-rails and
Propshaft. If the host app has not initialized Importmap and Stimulus, run:

```sh
bin/rails importmap:install
bin/rails stimulus:install
```

## Feedback button

### Configure

```ruby
# config/initializers/pocket_kit.rb
PocketKit.configure do |config|
  # The environment variable holding the command. Unset, blank, or malformed
  # values hide the button and turn the endpoint into a 404.
  config.feedback.command_env = "FEEDBACK_COMMAND"

  # First line of every note: "My app feedback (screen: notes#show)".
  config.feedback.heading = "My app feedback"

  # The command gets `--request-id my-app-feedback-<uuid> --json -`.
  config.feedback.request_id_prefix = "my-app-feedback"

  # Exit statuses that count as sent (default [0, 3]; 3 = saved, not yet announced).
  config.feedback.sent_exit_codes = [ 0, 3 ]

  # Who sees the button. Called with the controller.
  config.feedback.enabled = ->(controller) { controller.request.local? || Current.user&.admin? }

  # Extra hidden fields the form carries, and lines built from them under the heading.
  config.feedback.hidden_fields = [ :note_id ]
  config.feedback.context_lines = lambda do |controller|
    note = Note.find_by(id: controller.params[:note_id])
    note ? [ "Note: #{note.id}" ] : []
  end

  # The endpoint's parent class, so your sign-in filters apply (default "ApplicationController").
  config.feedback.parent_controller = "ApplicationController"
end
```

### The command

The variable is split into arguments like a shell would, but no shell runs it.
pocket-kit appends `--request-id <prefix>-<uuid> --json -` and writes the note
to the command's stdin. The command has 10 seconds to finish. Its output is
discarded; on timeout, pocket-kit terminates its process group and reports the
note as not sent.

```
My app feedback (screen: notes#show)
Note: 42

The save button is hard to find

Device:
Browser: Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) …
Screen: 390x844
Viewport: 390x664
Visual viewport: 390x400
Pixel ratio: 3
Home screen app: true
Color scheme: dark
```

Each device value is checked against a pattern and dropped if it does not
match. Notes are capped at 2000 characters and five a minute. The
screen must be a `controller#action` the app routes to, so the page cannot put
anything else in the message.

```sh
FEEDBACK_COMMAND="/usr/local/bin/file-note --to inbox"
```

### Show it

```erb
<%# app/views/layouts/application.html.erb %>
<head>
  <%= stylesheet_link_tag "pocket_kit/feedback" %>
  <%= javascript_importmap_tags %>
</head>
<body>
  <header>
    <h1>My app</h1>
    <%= pocket_kit_feedback %>
  </header>
```

Pass `screen:` to name the screen yourself and `fields:` for the hidden fields:

```erb
<%= pocket_kit_feedback(fields: { note_id: @note.id }) %>
```

The Stimulus controller is pinned as `controllers/pocket_kit/feedback_controller`,
so the standard `eagerLoadControllersFrom("controllers", application)` registers
it as `pocket-kit--feedback`. If you register controllers by hand:

```js
import FeedbackController from "controllers/pocket_kit/feedback_controller"
application.register("pocket-kit--feedback", FeedbackController)
```

After a send, "Sent" appears beside the button; a failure keeps the dialog open
with the text in it and says so inside the dialog. Nothing from the app's
layout or flash is needed.

### Style it

The stylesheet is plain CSS with custom properties. Set them in your own CSS:

```css
.pk-feedback {
  --pk-feedback-color: #1d1d1f;
  --pk-feedback-background: #fff;
  --pk-feedback-muted: #8a8a8e;
  --pk-feedback-border: #d2d2d7;
  --pk-feedback-radius: 8px;
  --pk-feedback-backdrop: rgba(0, 0, 0, 0.3);
  --pk-feedback-failed: #c0392b;
}
```

To change the markup, copy `app/views/pocket_kit/feedback/_feedback.html.erb`
into your app at the same path; Rails uses yours instead. Keep the ids, the
`data-` attributes and the field names. The text comes from I18n keys under
`pocket_kit.feedback` (see `config/locales/en.yml`), which your own locale
files can override.

## Adding a piece

Each piece keeps to its own files, so adding one does not change the others:

1. `lib/pocket_kit/<piece>.rb`: a `PocketKit::<Piece>` module, its settings as
   `PocketKit.<piece>`, and any initializer it needs (reopen `PocketKit::Engine`).
   Require it from `lib/pocket_kit.rb`.
2. `app/controllers/pocket_kit/`, `app/views/pocket_kit/<piece>/`: endpoints and
   partials, if it has any. Add its routes to `config/routes.rb`.
3. `app/assets/javascripts/pocket_kit/<piece>_controller.js` and
   `app/assets/stylesheets/pocket_kit/<piece>.css`; pin the controller in
   `config/importmap.rb` under `controllers/pocket_kit/`.
4. Text under `pocket_kit.<piece>` in `config/locales/en.yml`.
5. Tests in `test/<piece>/`, using the dummy app in `test/dummy`; show the
   piece in the dummy app's layout.
6. A section in this README.

## Development

```sh
bundle install
bundle exec rake test         # unit and integration tests
bundle exec rake test:system  # browser tests; needs Chrome or Chromium
```

## License

MIT. See [LICENSE](LICENSE).
