import json
import os
import shutil
import stat
import tempfile
import time
import unittest

import pocket_kit
from pocket_kit import Groups, Reporter, fingerprint

ENV_NAME = "POCKET_KIT_TEST_COMMAND"


def gone(pid, wait=2):
    """Whether the process has exited (a zombie not yet reaped counts as exited)."""
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        try:
            with open("/proc/%d/stat" % pid) as file:
                if file.read().rsplit(")", 1)[1].split()[0] == "Z":
                    return True
        except FileNotFoundError:
            return True
        except OSError:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
        time.sleep(0.05)
    return False


class ReporterTest(unittest.TestCase):
    """Runs a stand-in command that records its arguments and stdin next to itself."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.script = os.path.join(self.dir, "fake-command")
        with open(self.script, "w") as file:
            file.write('#!/bin/sh\nprintf \'%s\\n\' "$@" > "$(dirname "$0")/args"\n'
                       'cat > "$(dirname "$0")/stdin"\nexit "${FAKE_EXIT:-0}"\n')
        os.chmod(self.script, stat.S_IRWXU)
        os.environ[ENV_NAME] = self.script + " send"
        self.kit = Reporter(command_env=ENV_NAME, app="Mini", request_id_prefix="mini",
                            screens={"notes#show"})

    def tearDown(self):
        os.environ.pop(ENV_NAME, None)
        os.environ.pop("FAKE_EXIT", None)
        shutil.rmtree(self.dir)

    def recorded(self, name):
        path = os.path.join(self.dir, name)
        if not os.path.exists(path):
            return None
        with open(path) as file:
            return file.read()

    def report(self):
        stdin = self.recorded("stdin")
        return json.loads(stdin) if stdin else None

    def raise_error(self, note_id):
        try:
            raise ValueError("bad id %d" % note_id)
        except ValueError as error:
            return error

    def test_an_exception_is_sent_as_a_json_report(self):
        self.assertTrue(self.kit.report_error(self.raise_error(5), context=["Path: /notes/5"]))

        args = self.recorded("args").splitlines()
        self.assertEqual(["send", "--request-id"], args[:2])
        self.assertRegex(args[2], r"\Amini-[0-9a-f-]{36}\Z")
        self.assertEqual(["--json", "-"], args[3:])
        sent = self.report()
        self.assertEqual((1, "error", "Mini", "request"),
                         (sent["version"], sent["kind"], sent["app"], sent["source"]))
        self.assertEqual("ValueError", sent["error"]["class"])
        self.assertEqual("bad id 5", sent["error"]["message"])
        self.assertIn("test_pocket_kit.py", sent["error"]["backtrace"][0])
        self.assertEqual(["Path: /notes/5"], sent["context"])
        self.assertEqual(1, sent["group"]["count"])
        self.assertTrue(sent["text"].startswith("Mini error (source: request)\n\nValueError: bad id 5\n"))

    def test_repeats_are_counted_not_sent_until_the_window_passes(self):
        self.kit.groups.window = 0.3
        self.assertTrue(self.kit.report_error(self.raise_error(1)))
        os.remove(os.path.join(self.dir, "stdin"))

        self.assertIsNone(self.kit.report_error(self.raise_error(2)))
        self.assertIsNone(self.kit.report_error(self.raise_error(3)))
        self.assertIsNone(self.recorded("stdin"))

        time.sleep(0.35)
        self.assertTrue(self.kit.report_error(self.raise_error(4)))
        self.assertEqual(3, self.report()["group"]["count"])
        self.assertIn("Seen 3 times since", self.report()["text"])

    def test_nothing_runs_when_the_variable_is_unset_blank_or_malformed(self):
        for value in (None, "  ", "'unclosed"):
            if value is None:
                os.environ.pop(ENV_NAME, None)
            else:
                os.environ[ENV_NAME] = value
            self.assertFalse(self.kit.report_error(self.raise_error(1)))
            self.assertEqual(404, self.kit.handle_browser_report(b'{"kind":"error","message":"x"}'))
        self.assertIsNone(self.recorded("stdin"))

    def test_shell_metacharacters_stay_literal_arguments(self):
        marker = os.path.join(self.dir, "SHELL_RAN")
        os.environ[ENV_NAME] = "%s ';' touch %s" % (self.script, marker)
        self.kit.report_error(self.raise_error(1))

        self.assertEqual([";", "touch", marker], self.recorded("args").splitlines()[:3])
        self.assertFalse(os.path.exists(marker))

    def test_exit_status_decides_whether_it_was_sent(self):
        os.environ["FAKE_EXIT"] = "3"
        self.assertTrue(self.kit.report_feedback("Fine"))
        os.environ["FAKE_EXIT"] = "1"
        self.assertFalse(self.kit.report_feedback("Fine"))

    def test_a_command_past_the_timeout_is_killed(self):
        hanging = os.path.join(self.dir, "hanging-command")
        pid_file = os.path.join(self.dir, "child-pid")
        with open(hanging, "w") as file:
            file.write("#!/bin/sh\ntrap '' TERM\nsleep 30 &\necho $! > %s\nwait\n" % pid_file)
        os.chmod(hanging, stat.S_IRWXU)
        os.environ[ENV_NAME] = hanging
        self.kit.timeout = 0.5
        started = time.monotonic()

        self.assertFalse(self.kit.report_feedback("Hello"))
        self.assertLess(time.monotonic() - started, 5)
        with open(pid_file) as file:
            child = int(file.read())
        self.assertTrue(gone(child), "the command's child was left running")

    def test_feedback_from_the_page_is_checked_and_sent(self):
        body = json.dumps({"kind": "feedback", "text": "Tags please", "screen": "notes#show",
                           "device": {"pixel_ratio": "3", "screen": "390x844\nforged", "token": "x"}})

        self.assertEqual(200, self.kit.handle_browser_report(body.encode()))
        sent = self.report()
        self.assertEqual("feedback", sent["kind"])
        self.assertEqual("Tags please", sent["note"])
        self.assertEqual({"pixel_ratio": "3"}, sent["device"])
        self.assertEqual("Mini feedback (screen: notes#show)\n\nTags please\n\nDevice:\nPixel ratio: 3\n",
                         sent["text"])

    def test_empty_and_overlong_feedback_is_refused(self):
        for text in ("  ", "a" * (pocket_kit.MAX_NOTE + 1)):
            body = json.dumps({"kind": "feedback", "text": text}).encode()
            self.assertEqual(422, self.kit.handle_browser_report(body))
        self.assertIsNone(self.recorded("stdin"))

    def test_an_error_from_the_page_is_checked_and_sent(self):
        body = json.dumps({"kind": "error", "class": "Bad class\n", "message": "boom\u0007",
                           "stack": "TypeError: boom\n    at save (/static/app.js:3:9)",
                           "page": "https://elsewhere/", "screen": "pages#secret"})

        self.assertEqual(202, self.kit.handle_browser_report(body.encode()))
        sent = self.report()
        self.assertEqual("browser", sent["source"])
        self.assertEqual("Error", sent["error"]["class"])
        self.assertEqual("boom", sent["error"]["message"])
        self.assertEqual(["TypeError: boom", "at save (/static/app.js:3:9)"], sent["error"]["backtrace"])
        self.assertNotIn("page", sent)
        self.assertNotIn("screen", sent)

    def test_malformed_page_posts_are_refused(self):
        self.assertEqual(400, self.kit.handle_browser_report(b"not json"))
        self.assertEqual(400, self.kit.handle_browser_report(b"[1]"))
        self.assertEqual(422, self.kit.handle_browser_report(b'{"kind":"other"}'))
        self.assertEqual(422, self.kit.handle_browser_report(b'{"kind":"error","message":" "}'))
        self.assertEqual(413, self.kit.handle_browser_report(b" " * (pocket_kit.MAX_BODY + 1)))

    def test_page_posts_are_rate_limited(self):
        for i in range(pocket_kit.BROWSER_REPORTS_PER_MINUTE):
            self.kit.handle_browser_report(b"[]")
        self.assertEqual(429, self.kit.handle_browser_report(b'{"kind":"error","message":"x"}'))


class GroupsTest(unittest.TestCase):
    def test_the_fingerprint_ignores_numbers_and_addresses_in_the_message(self):
        base = fingerprint("KeyError", "missing 4 at 0x7f3a", "a.py:1")
        self.assertEqual(base, fingerprint("KeyError", "missing 52 at 0x9b00", "a.py:1"))
        self.assertNotEqual(base, fingerprint("ValueError", "missing 4 at 0x7f3a", "a.py:1"))
        self.assertNotEqual(base, fingerprint("KeyError", "missing 4 at 0x7f3a", "b.py:1"))

    def test_the_fingerprint_matches_the_rails_engine(self):
        self.assertEqual("f15f708a2de14776", fingerprint("ValueError", "bad id 42", "app.py:10"))

    def test_first_is_sent_repeats_held_next_after_window_carries_the_count(self):
        groups = Groups(60)
        self.assertEqual({"fingerprint": "f", "count": 1, "first_seen": 0, "last_seen": 0}, groups.record("f", 0))
        self.assertIsNone(groups.record("f", 10))
        self.assertIsNone(groups.record("f", 20))
        self.assertEqual({"fingerprint": "f", "count": 3, "first_seen": 10, "last_seen": 61},
                         groups.record("f", 61))
        self.assertEqual(1, groups.record("f", 200)["count"])

    def test_only_max_groups_fingerprints_are_remembered(self):
        groups = Groups(60)
        for i in range(pocket_kit.MAX_GROUPS + 1):
            groups.record("f%d" % i, 0)
        self.assertIsNotNone(groups.record("f0", 0))


if __name__ == "__main__":
    unittest.main()
