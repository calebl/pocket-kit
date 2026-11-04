"""pocket-kit for plain Python web apps. Standard library only; copy this file.

Sends errors and feedback notes to the same local command, in the same JSON
report, as pocket-kit's Rails engine (see "The report format" in the README):

    from pocket_kit import Reporter

    kit = Reporter(command_env="ERRORS_COMMAND", app="My app", request_id_prefix="my-app")

    try:
        handle(request)
    except Exception as error:
        kit.report_error(error, source="request")
        raise

    # The endpoint the page's script (pocket_kit.js) posts to:
    status = kit.handle_browser_report(request_body_bytes)

The command is never run through a shell. It gets
`--request-id <prefix>-<uuid> --json -` and the report on stdin, has 10
seconds to finish, and has its process group terminated after that. Repeat
errors are grouped by the same rule as the Rails engine. Nothing is sent
anywhere but the command.

With `replay_dir` set, a session replay the page posts with a note or an error
is checked, saved there as its own JSON file, and named in the report.
"""

import errno
import hashlib
import json
import math
import os
import re
import shlex
import signal
import subprocess
import threading
import time
import traceback
import uuid
from collections import OrderedDict
from datetime import datetime, timezone

VERSION = 1
COMMAND_TIMEOUT = 10
TERMINATION_GRACE = 1
MAX_GROUPS = 500
BACKTRACE_LINES = 20
MAX_NOTE = 2000
MAX_MESSAGE = 1000
MAX_STACK = 5000
MAX_FRAME = 300
MAX_BODY = 20000
BROWSER_REPORTS_PER_MINUTE = 30
MAX_REPLAY_BYTES = 1000000
REPLAY_KEEP = 100
FULL_SNAPSHOT = 2

CLASS_FORMAT = re.compile(r"\A[\w$.:]{1,100}\Z")
PAGE_FORMAT = re.compile(r"\A/[\x20-\x7e]{0,299}\Z")
SCREEN_FORMAT = re.compile(r"\A[\w./:-]{1,100}#\w{1,100}\Z")
UUID_FORMAT = re.compile(r"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z")
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")

# What the browser says about the device; a value is kept only if it matches.
DEVICE_FIELDS = OrderedDict([
    ("user_agent", ("Browser", re.compile(r"\A[\x20-\x7e]{1,300}\Z"))),
    ("screen", ("Screen", re.compile(r"\A\d{1,5}x\d{1,5}\Z"))),
    ("viewport", ("Viewport", re.compile(r"\A\d{1,5}x\d{1,5}\Z"))),
    ("visual_viewport", ("Visual viewport", re.compile(r"\A\d{1,5}x\d{1,5}\Z"))),
    ("pixel_ratio", ("Pixel ratio", re.compile(r"\A\d{1,2}(\.\d{1,4})?\Z"))),
    ("standalone", ("Home screen app", re.compile(r"\A(true|false)\Z"))),
    ("color_scheme", ("Color scheme", re.compile(r"\A(light|dark)\Z"))),
])


def fingerprint(error_class, message, top_frame):
    """The grouping key: numbers and 0x addresses in the message count as equal."""
    normalized = re.sub(r"\d+", "N", re.sub(r"0x[0-9a-fA-F]+", "N", str(message)))
    key = "%s\n%s\n%s" % (error_class, normalized, top_frame or "")
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]


def _timestamp(seconds):
    moment = datetime.fromtimestamp(seconds, timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)


class Groups:
    """The first occurrence of a fingerprint is sent at once; repeats within
    `window` seconds of the last send are only counted; the next occurrence
    after the window is sent with a count that includes the held repeats."""

    def __init__(self, window):
        self.window = window
        self._groups = OrderedDict()
        self._lock = threading.Lock()

    def record(self, key, now=None):
        now = time.time() if now is None else now
        with self._lock:
            group = self._groups.get(key)
            if group and (group["attempt"] is not None or
                          (group["sent_at"] is not None and now - group["sent_at"] < self.window)):
                group["held"] += 1
                if group["first_held"] is None:
                    group["first_held"] = now
                return None

            sent = {
                "fingerprint": key,
                "count": 1 + (group["held"] if group else 0),
                "first_seen": group["first_held"] if group and group["first_held"] is not None else now,
                "last_seen": now,
            }
            self._groups.pop(key, None)
            self._groups[key] = {"sent_at": None, "held": 0, "first_held": None, "attempt": sent}
            self._evict_inactive()
            return sent

    def commit(self, group, now=None):
        now = time.time() if now is None else now
        with self._lock:
            current = self._groups.get(group["fingerprint"])
            if not current or current["attempt"] is not group:
                return
            current["sent_at"] = now
            current["attempt"] = None
            self._evict_inactive()

    def rollback(self, group):
        with self._lock:
            current = self._groups.get(group["fingerprint"])
            if not current or current["attempt"] is not group:
                return
            current["sent_at"] = None
            current["held"] += group["count"]
            current["first_held"] = group["first_seen"]
            current["attempt"] = None
            self._evict_inactive()

    def _evict_inactive(self):
        while len(self._groups) > MAX_GROUPS:
            inactive = next((key for key, group in self._groups.items()
                             if group["attempt"] is None), None)
            if inactive is None:
                return
            self._groups.pop(inactive)


class Reporter:
    """Sends reports to the command named by an environment variable.

    Off (every call returns False) while the variable is unset, blank, or
    cannot be split. `screens`, if given, is the set of screen names the page
    may claim; any other screen is dropped.

    `replay_dir`, if given, turns on session replay: a replay posted with a
    browser report is saved there (at most `max_replay_bytes` of JSON, the
    newest `replay_keep` files kept) and named in the report. Without it, a
    posted replay is ignored.
    """

    def __init__(self, command_env="ERRORS_COMMAND", app="App", request_id_prefix="errors",
                 sent_exit_codes=(0, 3), group_window=600, screens=None, timeout=COMMAND_TIMEOUT,
                 replay_dir=None, max_replay_bytes=MAX_REPLAY_BYTES, replay_keep=REPLAY_KEEP):
        self.command_env = command_env
        self.app = app
        self.request_id_prefix = request_id_prefix
        self.sent_exit_codes = tuple(sent_exit_codes)
        self.groups = Groups(group_window)
        self.screens = screens
        self.timeout = timeout
        self.replay_dir = replay_dir
        self.max_replay_bytes = max_replay_bytes
        self.replay_keep = replay_keep
        self._browser_times = []
        self._replays_in_flight = set()
        self._lock = threading.Lock()

    def command(self):
        value = os.environ.get(self.command_env, "")
        if not value.strip():
            return None
        try:
            return shlex.split(value)
        except ValueError:
            return None

    def enabled(self):
        return self.command() is not None

    def report_error(self, error, source="request", context=None, screen=None, page=None):
        """Reports an exception. True when sent, False when the piece is off or
        the command failed, None when held back as a repeat."""
        frames = traceback.extract_tb(error.__traceback__)
        backtrace = ['%s:%d:in %s' % (frame.filename, frame.lineno, frame.name) for frame in reversed(frames)]
        return self._report_error(type(error).__name__, str(error), backtrace, source, context, screen, page)

    def report_feedback(self, text, screen=None, context=None, device=None, request_id=None, replay=None):
        """Sends a feedback note. True when the command took it. `replay` is
        the JSON string of rrweb events the page posted, if any."""
        text = str(text).strip()
        if not text or len(text) > MAX_NOTE or (request_id is not None and
                                                not (isinstance(request_id, str) and
                                                     UUID_FORMAT.match(request_id))):
            return False
        context = list(context or [])
        device = self.device(device or {})
        heading = "%s feedback" % self.app + (" (screen: %s)" % screen if screen else "")
        message = "\n".join([heading] + context) + "\n\n" + text + "\n"
        if device:
            message += "\nDevice:\n" + "".join("%s: %s\n" % (DEVICE_FIELDS[k][0], v) for k, v in device.items())
        saved = self.store_replay(replay)
        if saved:
            message += "\nReplay: %s\n" % saved["path"]
        report = {
            "version": VERSION, "kind": "feedback", "app": self.app, "source": "browser",
            "occurred_at": _timestamp(time.time()), "screen": screen, "text": message, "note": text,
            "context": context, "device": device,
        }
        if saved:
            report["replay"] = saved
        delivered = False
        try:
            delivered = self._send(report, request_id=request_id)
            return delivered
        finally:
            self._complete_replay(saved, delivered)

    def store_replay(self, value):
        """Checks a posted replay (a JSON string of rrweb events) and saves it in
        replay_dir. Returns {"path", "events"}, or None when replay is off or the
        replay is missing, too big, not rrweb events with a full snapshot, or
        cannot be written."""
        if not self.replay_dir or not isinstance(value, str) or not value:
            return None
        if len(value.encode("utf-8")) > self.max_replay_bytes:
            return None
        try:
            events = json.loads(value)
        except (ValueError, RecursionError):
            return None
        if not (isinstance(events, list) and events and
                all(isinstance(event, dict) and type(event.get("type")) is int and
                    type(event.get("timestamp")) in (int, float) for event in events) and
                any(event["type"] == FULL_SNAPSHOT for event in events) and
                self._finite_numbers(events)):
            return None
        path = os.path.join(self.replay_dir, "%s.json" % uuid.uuid4())
        try:
            os.makedirs(self.replay_dir, mode=0o700, exist_ok=True)
            with self._lock:
                self._replays_in_flight.add(os.path.abspath(path))
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as file:
                json.dump(events, file, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
            self._prune_replays()
        except (OSError, ValueError, RecursionError):
            with self._lock:
                self._replays_in_flight.discard(os.path.abspath(path))
            self._remove_replay({"path": path})
            return None
        return {"path": os.path.abspath(path), "events": len(events)}

    @classmethod
    def _finite_numbers(cls, value):
        if isinstance(value, float):
            return math.isfinite(value)
        if isinstance(value, list):
            return all(cls._finite_numbers(item) for item in value)
        if isinstance(value, dict):
            return all(cls._finite_numbers(item) for item in value.values())
        return True

    def _complete_replay(self, replay, delivered):
        if not replay:
            return
        with self._lock:
            self._replays_in_flight.discard(replay["path"])
        if delivered:
            try:
                self._prune_replays()
            except OSError:
                pass
        else:
            self._remove_replay(replay)

    @staticmethod
    def _remove_replay(replay):
        if not replay:
            return
        try:
            os.remove(replay["path"])
        except OSError:
            pass

    def _prune_replays(self):
        with self._lock:
            files = [os.path.join(self.replay_dir, name) for name in os.listdir(self.replay_dir)
                     if name.endswith(".json") and
                     os.path.abspath(os.path.join(self.replay_dir, name)) not in self._replays_in_flight]
            files.sort(key=lambda name: os.stat(name).st_mtime)
            for name in files[:max(len(files) - self.replay_keep, 0)]:
                try:
                    os.remove(name)
                except OSError as error:
                    if error.errno != errno.ENOENT:
                        raise

    def handle_browser_report(self, body):
        """Handles a JSON body posted by pocket_kit.js (an error or a feedback
        note). Returns the HTTP status to answer with."""
        if not self.enabled():
            return 404
        if not self._take_browser_slot():
            return 429
        # A replay rides inside the body as an escaped JSON string, up to twice its size.
        limit = MAX_BODY + (2 * self.max_replay_bytes if self.replay_dir else 0)
        if isinstance(body, (bytes, bytearray)):
            if len(body) > limit:
                return 413
            body = body.decode("utf-8", "replace")
        elif isinstance(body, str) and len(body.encode("utf-8")) > limit:
            return 413
        try:
            payload = json.loads(body)
        except ValueError:
            return 400
        if not isinstance(payload, dict):
            return 400

        screen = self._screen(payload.get("screen"))
        if payload.get("kind") == "feedback":
            request_id = payload.get("request_id")
            if not (isinstance(request_id, str) and UUID_FORMAT.match(request_id)):
                return 422
            return 200 if self.report_feedback(_string(payload.get("text")), screen=screen,
                                               device=payload.get("device"), request_id=request_id,
                                               replay=payload.get("replay")) else 422
        if payload.get("kind") != "error":
            return 422

        message = _clean(payload.get("message"), MAX_MESSAGE)
        if not message:
            return 422
        error_class = payload.get("class")
        if not (isinstance(error_class, str) and CLASS_FORMAT.match(error_class)):
            error_class = "Error"
        stack = _clean(payload.get("stack"), MAX_STACK)
        backtrace = [line.strip()[:MAX_FRAME] for line in stack.splitlines() if line.strip()]
        page = payload.get("page")
        page = page if isinstance(page, str) and PAGE_FORMAT.match(page) else None
        accepted = self._report_error(error_class, message, backtrace, "browser", None, screen, page,
                                      replay=payload.get("replay"))
        return 503 if accepted is False else 202

    @staticmethod
    def device(values):
        if not isinstance(values, dict):
            return {}
        kept = {}
        for field, (_label, pattern) in DEVICE_FIELDS.items():
            value = values.get(field)
            if isinstance(value, str) and pattern.match(value.strip()):
                kept[field] = value.strip()
        return kept

    def _screen(self, value):
        if not (isinstance(value, str) and SCREEN_FORMAT.match(value)):
            return None
        return value if self.screens is None or value in self.screens else None

    def _take_browser_slot(self):
        now = time.monotonic()
        with self._lock:
            self._browser_times = [t for t in self._browser_times if now - t < 60]
            if len(self._browser_times) >= BROWSER_REPORTS_PER_MINUTE:
                return False
            self._browser_times.append(now)
            return True

    def _report_error(self, error_class, message, backtrace, source, context, screen, page, replay=None):
        if not self.enabled():
            return False
        if source == "browser":
            while backtrace:
                first = backtrace[0]
                if first.startswith("at ") or "@" in first or re.search(r":\d+", first):
                    break
                backtrace = backtrace[1:]
        backtrace = backtrace[:BACKTRACE_LINES]
        group = self.groups.record(fingerprint(error_class, message, backtrace[0] if backtrace else ""))
        if group is None:
            return None

        lines = ["%s error (source: %s)" % (self.app, source), "", "%s: %s" % (error_class, message)]
        lines += ["  " + frame for frame in backtrace[:10]]
        if group["count"] > 1:
            lines += ["", "Seen %d times since %s" % (group["count"], _timestamp(group["first_seen"]))]
        saved = self.store_replay(replay)
        if saved:
            lines += ["", "Replay: %s" % saved["path"]]
        report = {
            "version": VERSION, "kind": "error", "app": self.app, "source": source,
            "occurred_at": _timestamp(time.time()), "screen": screen, "page": page,
            "text": "\n".join(lines) + "\n", "context": list(context or []),
            "error": {"class": error_class, "message": message, "backtrace": backtrace},
            "group": dict(group, first_seen=_timestamp(group["first_seen"]),
                          last_seen=_timestamp(group["last_seen"])),
            "replay": saved,
        }
        report = {key: value for key, value in report.items() if value is not None}
        delivered = False
        try:
            delivered = self._send(report)
            return delivered
        finally:
            if delivered:
                self.groups.commit(group)
            else:
                self.groups.rollback(group)
            self._complete_replay(saved, delivered)

    def _send(self, report, request_id=None):
        command = self.command()
        if command is None:
            return False
        request_id = request_id or str(uuid.uuid4())
        argv = command + ["--request-id", "%s-%s" % (self.request_id_prefix, request_id), "--json", "-"]
        body = (json.dumps(report, separators=(",", ":")) + "\n").encode("utf-8")
        try:
            process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            return False
        try:
            process.communicate(body, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            _terminate(process)
            return False
        except OSError:
            process.wait()
        return process.returncode in self.sent_exit_codes


def _terminate(process):
    for sig, wait in ((signal.SIGTERM, TERMINATION_GRACE), (signal.SIGKILL, None)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        if wait:
            time.sleep(wait)
    process.wait()


def _string(value):
    return value if isinstance(value, str) else ""


def _clean(value, limit):
    """The text with control characters other than newlines and tabs removed, capped."""
    if not isinstance(value, str):
        return ""
    return CONTROL.sub("", value).strip()[:limit]
