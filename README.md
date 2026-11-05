# pocket-kit

Small shared pieces for self-hosted phone web apps: apps that run on your own
machine and that you reach from your phone over a VPN such as Tailscale.

pocket-kit is a framework-free core with adapters on top. The core is one plain
JavaScript file for the page and one JSON report handed to a local command you
choose. The Rails engine (this Ruby gem) and a small Python helper are the
adapters. Each piece is separate and optional. Today it has:

- **Feedback button**: a small button that opens a dialog; the note typed into
  it goes to a local command you choose, along with the screen it was sent from
  and what the device reports about itself.
- **Errors**: uncaught page errors, unhandled request exceptions and Active Job
  exceptions go to a local command you choose. Repeats are grouped, so a burst
  runs the command once.
- **Session replay** (opt-in): the page keeps the last ~30 seconds of activity
  in memory, recorded with a vendored copy of [rrweb](https://github.com/rrweb-io/rrweb),
  and sends it along with a feedback note or a page error. The app saves it as
  a file, the report names the file, and a local viewer plays it back.

Nothing leaves the machine: the page posts only to the app's own paths, and the
app hands reports only to the local command. There is no third-party service,
telemetry, or CDN.

Coming next: pinning the header to the iPhone's visible viewport.

The repo also documents the pattern these apps follow (localhost only, the
VPN's https address in front, a start script and service, settings outside the
repo, a home-screen icon, and a deploy checklist): see
[docs/local-app-pattern.md](docs/local-app-pattern.md) and the
[templates](templates/).

## Install

```ruby
# Gemfile
gem "pocket_kit", github: "calebl/pocket-kit", tag: "v0.3.0"
```

```ruby
# config/routes.rb
mount PocketKit::Engine, at: "/pocket-kit"
```

pocket-kit needs Rails 8, turbo-rails, importmap-rails, and stimulus-rails.
The JavaScript is the browser core, `pocket_kit.js`, pinned as `pocket_kit`,
and a Stimulus controller over it, served through importmap-rails and
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

  # What goes on stdin: :text, the message below (default), or :json, the
  # shared report (see "The report format").
  config.feedback.format = :text

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

## Errors

Off until you name the command's environment variable.

### Configure

```ruby
# config/initializers/pocket_kit.rb
PocketKit.configure do |config|
  # The environment variable holding the command. Not set here, or unset,
  # blank, or malformed in the environment: nothing is reported.
  config.errors.command_env = "ERRORS_COMMAND"

  # First in every report's text: "My app error (source: request)".
  config.errors.heading = "My app"

  # The command gets `--request-id my-app-errors-<uuid> --json -`.
  config.errors.request_id_prefix = "my-app-errors"

  # Exit statuses that count as sent (default [0, 3]).
  config.errors.sent_exit_codes = [ 0, 3 ]

  # Seconds a repeat is only counted after its error was sent (default 600).
  config.errors.group_window = 600

  # Which errors are reported (all default to true).
  config.errors.requests = true  # unhandled exceptions in requests
  config.errors.jobs = true      # exceptions that escape an Active Job
  config.errors.browser = true   # errors posted by the page

  # Who may post page errors. Called with the controller.
  config.errors.enabled = ->(controller) { true }

  # The page-error endpoint's parent class (default "ApplicationController").
  config.errors.parent_controller = "ApplicationController"
end
```

The command is run the same way as the feedback command (no shell,
`--request-id <prefix>-<uuid> --json -` appended, 10 seconds), with the JSON
report on stdin. It runs on a background thread, so a failing request or job
is not held up by it. Rails queues at most 100 reports; if that queue is full,
the report remains eligible for a later attempt.

What is reported:

- **Requests**: exceptions Rails reports as unhandled from a request (the ones
  that end in a 500). Exceptions the app rescues are not reported.
- **Jobs**: exceptions that escape a job's `perform_now`, after its own
  `retry_on`, `discard_on` and `rescue_from` handlers. The report's context has
  `Job: <class>`.
- **Page errors**: uncaught errors and unhandled promise rejections, caught by
  the browser core and posted to the engine's `errors` endpoint. Each value is
  checked and capped (class name, 1000-character message, 20 stack lines, a
  path for the page, a routed `controller#action` for the screen); anything
  else is dropped. The endpoint takes 30 errors a minute.

### Show it

Put the tag in `<head>` and load the browser core before anything else that
could fail:

```erb
<head>
  <%= pocket_kit_errors_tag %>
  <%= javascript_importmap_tags %>
</head>
```

```js
// app/javascript/application.js
import "pocket_kit"
```

The tag names the endpoint and the screen; the page posts nothing without it.
The page posts each distinct error once, and at most 10 per page load. If the
local command fails, the same error on that page is not re-sent until the page
reloads.

### Grouping

Repeat errors are grouped by fingerprint: the first 16 hex characters of the
SHA-256 of `<class>\n<message>\n<top frame>`, where every `0x…` hex number and
every run of digits in the message counts as `N`, so "Note 4 not found" and
"Note 52 not found" are the same error.

- The first occurrence of a fingerprint runs the command at once.
- Repeats within `group_window` seconds of that are only counted.
- The next occurrence after the window runs the command, with `group.count`
  covering the repeats held back since the last send.

A burst that stops inside the window is reported once; its count comes with
the next occurrence, if there is one. Each process keeps its own groups in
memory and remembers at most 500 inactive fingerprints.

## Session replay

Off by default. When an app turns it on, each page records what happens on it
with rrweb (the open-source recorder Sentry's replays are built on) and keeps
about the last 30 seconds in memory: never in localStorage, IndexedDB, cookies,
or the network. When a feedback note or a page error is posted, that recording
goes with it, to the same endpoint on the app's own origin. With replay off,
the recorder is never loaded and reports are exactly as before.

### Turn it on

```ruby
# config/initializers/pocket_kit.rb
PocketKit.configure do |config|
  # true, or false (the default), for the whole app.
  config.replay.enabled = true

  # Show user-editable text in replays (default false: masked).
  config.replay.show_typed_text = false

  # Where replays are saved (default tmp/pocket_kit/replays in the app).
  config.replay.directory = Rails.root.join("storage/replays")

  # Largest replay accepted, in bytes of JSON (default 1_000_000), and the
  # retention target once files are old enough to prune (default 100).
  config.replay.max_bytes = 1_000_000
  config.replay.keep = 100

  # How long a replay is kept, in seconds or a Duration (default 7 days).
  config.replay.max_age = 3.days

  # Who may open the replay pages. Called with the controller; the default
  # allows only requests made on this machine (see "Watch a replay").
  config.replay.viewer = ->(controller) { PocketKit::Replay.local_request?(controller.request) }

  # The replay pages' parent class (default "ApplicationController").
  config.replay.parent_controller = "ApplicationController"
end
```

Then put the tag in `<head>`, next to the others:

```erb
<head>
  <%= pocket_kit_errors_tag %>
  <%= pocket_kit_replay_tag %>
  <%= javascript_importmap_tags %>
</head>
```

The tag renders only when replay is on and the page could send a report (the
feedback button or page errors are on). The browser core then
loads the recorder from the app's own assets and starts recording.

### Privacy

- **Typed text is masked.** Everything typed into inputs, textareas, selects,
  and `contenteditable` elements is recorded as `*` unless `show_typed_text`
  is true. Passwords are always masked.
- **Hide more with rrweb's classes.** Other text on the page is recorded as
  shown. For anything else private, such as the displayed text of a note, add
  one of rrweb's classes:
  - `rr-block`: the element is not recorded at all; the replay shows an empty
    box of the same size.
  - `rr-mask`: the element's text, and its children's, is replaced with `*`.
  - `rr-ignore`: input events in the element are not recorded.
- The recording lives only in the page's memory and is dropped when the page
  is closed. It is sent only with a report, only to the app's own endpoint.
- The page caps what it sends at `max_bytes`, dropping its oldest seconds
  first; the server refuses anything bigger, or anything that is not rrweb
  events with a full snapshot. A refused replay, or one that fails to record or
  save, is left out and the report is still sent.
- `replay` is added to the app's `filter_parameters`, so replays stay out of
  the log.
- Playback blocks resources recorded from other origins, so watching a replay
  does not contact those sites. The in-app viewer may load the app's own
  same-origin resources.

### Where replays go

The server saves each accepted replay as `<uuid>.json` (a JSON array of rrweb
events) in the replay directory, readable only by the app's user, and the
report names it instead of carrying it. The text format gets a last line:

```
Replay: /srv/my-app/tmp/pocket_kit/replays/5f0c…json
```

and the JSON report gets a `replay` field (see "The report format"). A replay
is deleted when its report is not delivered, and a repeat error held back by
grouping saves no replay. Retention pruning keeps the newest `keep` files once
they are older than the delivery grace period, so recent or in-flight reports
can temporarily leave more files than that target.

Replays expire: a replay older than `max_age` (default 7 days) is deleted, and
is never played even before it is deleted. Expired replays are cleaned up on
every save, when the app starts, and whenever a replay page is opened, so they
go even when no new reports arrive. A replay still inside the delivery grace
period is never deleted, so a `max_age` shorter than that grace acts as the
grace. Change it per app with `config.replay.max_age` (Rails) or
`replay_max_age` in seconds (Python).

### Watch one

- **In the app**: open the report's `replay.viewer` path, e.g.
  `/pocket-kit/replays/<uuid>`, on the app's own address. It plays the replay
  with the vendored rrweb player. The replay pages are for this machine only:
  they answer a request only when it connects from a loopback address and no
  forwarding header (`X-Forwarded-For`, `Forwarded`, `X-Real-IP` and the like)
  names any other client. A request through `tailscale serve` or another
  proxy, from the tailnet or anywhere else, gets a 404; open the app's local
  address (e.g. `http://127.0.0.1:<port>`) on the machine itself. Replacing
  `config.replay.viewer` with a wider check exposes recorded screens to
  everyone it lets in.
- **With no server**: open `viewer/replay.html` from a pocket-kit checkout (or
  the installed gem's directory, `bundle exec gem contents pocket_kit | grep
  viewer`) in a browser and pick the replay file. It loads only the vendored
  files beside it.

rrweb is vendored, pinned to 2.1.7 (`@rrweb/record` and `rrweb-player`), with
its MIT licence, in `app/assets/javascripts/pocket_kit/vendor/`; see the README
there.

## The report format

Both pieces can hand the command the same JSON object, one line on stdin.
Errors always use it; feedback uses it with `config.feedback.format = :json`.
The Python helper sends the same object.

```json
{
  "version": 1,
  "kind": "error",
  "app": "My app",
  "source": "request",
  "occurred_at": "2026-10-28T13:45:01.123Z",
  "screen": "notes#show",
  "page": "/notes/7",
  "text": "My app error (source: request)\n\nNoMethodError: undefined method 'title' for nil\n  app/controllers/notes_controller.rb:12:in 'show'\n",
  "context": [],
  "error": {
    "class": "NoMethodError",
    "message": "undefined method 'title' for nil",
    "backtrace": [ "app/controllers/notes_controller.rb:12:in 'show'" ]
  },
  "group": {
    "fingerprint": "3f9a0c2e9b11d4a6",
    "count": 3,
    "first_seen": "2026-10-28T13:35:00.512Z",
    "last_seen": "2026-10-28T13:45:01.123Z"
  }
}
```

| Field | |
| --- | --- |
| `version` | `1`. A change that breaks a reader gets a new number. |
| `kind` | `"error"` or `"feedback"`. |
| `app` | The configured heading. |
| `source` | `"browser"`, `"request"`, or `"job"` (or what the Python helper is given). |
| `occurred_at` | When the report was made, UTC. |
| `screen` | `controller#action`, when known. |
| `page` | The page's path, for page errors. Omitted otherwise. |
| `text` | A plain-text message for a human; a command that only forwards text can use this alone. For feedback it is the text format's message. |
| `context` | Extra lines from the app, e.g. `"Note: 42"` or `"Job: ImportJob"`. |
| `note` | Feedback only: the note as typed. |
| `device` | Feedback only: the checked device fields, keyed as in the form. |
| `error` | Errors only: `class`, `message`, and up to 20 `backtrace` lines. |
| `group` | Errors only: `fingerprint`, `count` (occurrences this report stands for), `first_seen`, `last_seen`. |
| `replay` | Only with session replay on and a replay accepted: `path` (the saved file), `events` (how many), and, from Rails, `viewer` (the path that plays it). |

## The browser core

`app/assets/javascripts/pocket_kit/pocket_kit.js` is one plain file with no
dependencies and no build step. Rails apps get it through importmap as
`pocket_kit`; any other app can copy it and load it with
`<script src="/static/pocket_kit.js"></script>`. It sets `window.PocketKit`
and starts on its own:

- With `<meta name="pocket-kit-errors" content="/path">` in the page, it posts
  uncaught errors and unhandled promise rejections to that path as
  `{"kind": "error", "class", "message", "stack", "page", "screen"}`. The
  optional `<meta name="pocket-kit-screen" content="notes#show">` names the
  screen. `PocketKit.reportError(error)` posts one by hand.
- Each element with `data-pk-feedback="/path"` becomes a feedback button. The
  note is posted to that path as
  `{"kind": "feedback", "text", "screen", "request_id", "device"}`:

```html
<div data-pk-feedback="/pocket-kit/report" data-pk-screen="notes#show">
  <button type="button" data-pk-open aria-label="Send feedback">Feedback</button>
  <span data-pk-sent role="status">Sent</span>
  <dialog aria-label="Send feedback">
    <form>
      <textarea name="text" maxlength="2000" required></textarea>
      <p data-pk-failed role="status">Couldn't send. Your note is still here.</p>
      <button type="button" data-pk-close>Cancel</button>
      <button>Send</button>
    </form>
  </dialog>
</div>
```

- With `<meta name="pocket-kit-replay" content="/path/rrweb-record-2.1.7.min.js">`
  in the page, it loads that same-origin recorder and keeps the last ~30
  seconds in memory, adding them as `"replay"` (a JSON string of rrweb events)
  to each error and note it posts. `data-show-typed-text="true"` on the tag
  stops masking user-editable text, and `data-max-bytes` caps the replay
  (default 1000000). `PocketKit.replayEvents()` returns the current recording.

The core posts only to paths on the page's own origin, sends the page's
`csrf-token` meta tag as `X-CSRF-Token` when there is one, and treats any 2xx
answer as sent.

## Python apps

`python/pocket_kit.py` is a standard-library-only module: copy it into the
app. It sends errors and feedback through the same kind of command, in the same
report, grouped by the same rule.

```python
from pocket_kit import Reporter

kit = Reporter(command_env="ERRORS_COMMAND", app="My app", request_id_prefix="my-app")

# Where the app handles a request:
try:
    response = handle(request)
except Exception as error:
    kit.report_error(error, source="request", context=["Path: " + request.path])
    raise

# The path the page's pocket_kit.js posts to (both errors and feedback):
status = kit.handle_browser_report(request_body_bytes)
```

`Reporter` also takes `sent_exit_codes` (default `(0, 3)`), `group_window`
(default 600 seconds), and `screens`, the set of screen names a page may
claim. For session replay, pass `replay_dir` (off without it), and optionally
`max_replay_bytes` (default 1000000), `replay_keep` (default 100, reached
once files are old enough to prune) and `replay_max_age` (seconds, default 7
days; expired replays are deleted when the `Reporter` is created, on every
save, and by `expire_replays()`); serve
`rrweb-record-2.1.7.min.js` from `app/assets/javascripts/pocket_kit/vendor/`
next to `pocket_kit.js` and add the `pocket-kit-replay` meta tag (see "The
browser core"). If you change `max_replay_bytes`, put the same value in the
meta tag's `data-max-bytes`. Replays are viewed with `viewer/replay.html`.
`report_feedback(text, screen=None, context=None, device=None,
request_id=None, replay=None)` sends a note directly. The command runs in the calling thread
and has 10 seconds.
`handle_browser_report` checks and caps every field the same way the Rails
engine does and returns the HTTP status to answer with: 202 or 200 when
accepted, 404 when no command is configured, 400, 413 or 422 for a bad post,
429 past 30 a minute.

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
(cd python && python3 -m unittest)  # the Python helper
```

## License

MIT. See [LICENSE](LICENSE).
