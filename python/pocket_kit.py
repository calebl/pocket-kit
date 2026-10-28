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
"""

import hashlib
import json
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

CLASS_FORMAT = re.compile(r"\A[\w$.:]{1,100}\Z")
PAGE_FORMAT = re.compile(r"\A/[\x20-\x7e]{0,299}\Z")
SCREEN_FORMAT = re.compile(r"\A[\w./:-]{1,100}#\w{1,100}\Z")
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
            if group and (group["attempt"] is not None or now - group["sent_at"] < self.window):
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
            while len(self._groups) > MAX_GROUPS:
                self._groups.popitem(last=False)
            return sent

    def commit(self, group, now=None):
        now = time.time() if now is None else now
        with self._lock:
            current = self._groups.get(group["fingerprint"])
            if not current or current["attempt"] is not group:
                return
            current["sent_at"] = now
            current["attempt"] = None

    def rollback(self, group):
        with self._lock:
            current = self._groups.get(group["fingerprint"])
            if not current or current["attempt"] is not group:
                return
            current["sent_at"] = float("-inf")
            current["held"] += group["count"]
            current["first_held"] = group["first_seen"]
            current["attempt"] = None


class Reporter:
    """Sends reports to the command named by an environment variable.

    Off (every call returns False) while the variable is unset, blank, or
    cannot be split. `screens`, if given, is the set of screen names the page
    may claim; any other screen is dropped.
    """

    def __init__(self, command_env="ERRORS_COMMAND", app="App", request_id_prefix="errors",
                 sent_exit_codes=(0, 3), group_window=600, screens=None, timeout=COMMAND_TIMEOUT):
        self.command_env = command_env
        self.app = app
        self.request_id_prefix = request_id_prefix
        self.sent_exit_codes = tuple(sent_exit_codes)
        self.groups = Groups(group_window)
        self.screens = screens
        self.timeout = timeout
        self._browser_times = []
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

    def report_feedback(self, text, screen=None, context=None, device=None):
        """Sends a feedback note. True when the command took it."""
        text = str(text).strip()
        if not text or len(text) > MAX_NOTE:
            return False
        context = list(context or [])
        device = self.device(device or {})
        heading = "%s feedback" % self.app + (" (screen: %s)" % screen if screen else "")
        message = "\n".join([heading] + context) + "\n\n" + text + "\n"
        if device:
            message += "\nDevice:\n" + "".join("%s: %s\n" % (DEVICE_FIELDS[k][0], v) for k, v in device.items())
        report = {
            "version": VERSION, "kind": "feedback", "app": self.app, "source": "browser",
            "occurred_at": _timestamp(time.time()), "screen": screen, "text": message, "note": text,
            "context": context, "device": device,
        }
        return self._send(report)

    def handle_browser_report(self, body):
        """Handles a JSON body posted by pocket_kit.js (an error or a feedback
        note). Returns the HTTP status to answer with."""
        if not self.enabled():
            return 404
        if not self._take_browser_slot():
            return 429
        if isinstance(body, (bytes, bytearray)):
            if len(body) > MAX_BODY:
                return 413
            body = body.decode("utf-8", "replace")
        try:
            payload = json.loads(body)
        except ValueError:
            return 400
        if not isinstance(payload, dict):
            return 400

        screen = self._screen(payload.get("screen"))
        if payload.get("kind") == "feedback":
            return 200 if self.report_feedback(_string(payload.get("text")), screen=screen,
                                               device=payload.get("device")) else 422
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
        accepted = self._report_error(error_class, message, backtrace, "browser", None, screen, page)
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

    def _report_error(self, error_class, message, backtrace, source, context, screen, page):
        if not self.enabled():
            return False
        backtrace = backtrace[:BACKTRACE_LINES]
        group = self.groups.record(fingerprint(error_class, message, backtrace[0] if backtrace else ""))
        if group is None:
            return None

        lines = ["%s error (source: %s)" % (self.app, source), "", "%s: %s" % (error_class, message)]
        lines += ["  " + frame for frame in backtrace[:10]]
        if group["count"] > 1:
            lines += ["", "Seen %d times since %s" % (group["count"], _timestamp(group["first_seen"]))]
        report = {
            "version": VERSION, "kind": "error", "app": self.app, "source": source,
            "occurred_at": _timestamp(time.time()), "screen": screen, "page": page,
            "text": "\n".join(lines) + "\n", "context": list(context or []),
            "error": {"class": error_class, "message": message, "backtrace": backtrace},
            "group": dict(group, first_seen=_timestamp(group["first_seen"]),
                          last_seen=_timestamp(group["last_seen"])),
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

    def _send(self, report):
        command = self.command()
        if command is None:
            return False
        argv = command + ["--request-id", "%s-%s" % (self.request_id_prefix, uuid.uuid4()), "--json", "-"]
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
