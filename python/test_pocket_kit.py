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
REQUEST_ID = "0b6f1c1e-6a51-4d6a-9d3e-3f3a0c2e9b11"


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

    def test_a_command_failure_does_not_suppress_the_next_matching_error(self):
        os.environ["FAKE_EXIT"] = "1"
        self.assertFalse(self.kit.report_error(self.raise_error(1)))
        os.remove(os.path.join(self.dir, "stdin"))

        os.environ["FAKE_EXIT"] = "0"
        self.assertTrue(self.kit.report_error(self.raise_error(2)))
        self.assertEqual(2, self.report()["group"]["count"])

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
                           "request_id": REQUEST_ID,
                           "device": {"pixel_ratio": "3", "screen": "390x844\nforged", "token": "x"}})

        self.assertEqual(200, self.kit.handle_browser_report(body.encode()))
        sent = self.report()
        self.assertEqual("mini-" + REQUEST_ID, self.recorded("args").splitlines()[2])
        self.assertEqual("feedback", sent["kind"])
        self.assertEqual("Tags please", sent["note"])
        self.assertEqual({"pixel_ratio": "3"}, sent["device"])
        self.assertEqual("Mini feedback (screen: notes#show)\n\nTags please\n\nDevice:\nPixel ratio: 3\n",
                         sent["text"])

    def test_a_feedback_retry_keeps_the_posted_request_id(self):
        body = json.dumps({"kind": "feedback", "text": "Retry me", "request_id": REQUEST_ID}).encode()
        os.environ["FAKE_EXIT"] = "1"
        self.assertEqual(422, self.kit.handle_browser_report(body))
        first_args = self.recorded("args")

        os.environ["FAKE_EXIT"] = "0"
        self.assertEqual(200, self.kit.handle_browser_report(body))
        self.assertEqual(first_args, self.recorded("args"))

    def test_invalid_feedback_fields_are_refused(self):
        payloads = [
            {"kind": "feedback", "text": "  ", "request_id": REQUEST_ID},
            {"kind": "feedback", "text": "a" * (pocket_kit.MAX_NOTE + 1), "request_id": REQUEST_ID},
            {"kind": "feedback", "text": "Fine"},
            {"kind": "feedback", "text": "Fine", "request_id": "not-a-uuid"},
        ]
        for payload in payloads:
            self.assertEqual(422, self.kit.handle_browser_report(json.dumps(payload).encode()))
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

    def test_browser_errors_with_the_same_summary_but_different_top_frames_are_separate_groups(self):
        first_body = json.dumps({"kind": "error", "class": "TypeError", "message": "boom",
                                 "stack": "TypeError: boom\n    at alpha (/static/app.js:3:9)"}).encode()
        second_body = json.dumps({"kind": "error", "class": "TypeError", "message": "boom",
                                  "stack": "TypeError: boom\n    at beta (/static/app.js:8:4)"}).encode()
        self.assertEqual(202, self.kit.handle_browser_report(first_body))
        first = self.report()
        self.assertEqual(["at alpha (/static/app.js:3:9)"], first["error"]["backtrace"])
        os.remove(os.path.join(self.dir, "stdin"))

        self.assertEqual(202, self.kit.handle_browser_report(second_body))
        second = self.report()
        self.assertIsNotNone(second)
        self.assertNotEqual(first["group"]["fingerprint"], second["group"]["fingerprint"])

    def test_a_page_error_reports_command_failure_and_can_be_retried(self):
        body = json.dumps({"kind": "error", "message": "boom"}).encode()
        os.environ["FAKE_EXIT"] = "1"
        self.assertEqual(503, self.kit.handle_browser_report(body))
        os.remove(os.path.join(self.dir, "stdin"))

        os.environ["FAKE_EXIT"] = "0"
        self.assertEqual(202, self.kit.handle_browser_report(body))
        self.assertEqual(2, self.report()["group"]["count"])

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
        first = groups.record("f", 0)
        self.assertEqual({"fingerprint": "f", "count": 1, "first_seen": 0, "last_seen": 0}, first)
        groups.commit(first, 0)
        self.assertIsNone(groups.record("f", 10))
        self.assertIsNone(groups.record("f", 20))
        later = groups.record("f", 61)
        self.assertEqual({"fingerprint": "f", "count": 3, "first_seen": 10, "last_seen": 61}, later)
        groups.commit(later, 61)
        self.assertEqual(1, groups.record("f", 200)["count"])

    def test_a_failed_delivery_restores_its_occurrence_and_repeats(self):
        groups = Groups(60)
        attempt = groups.record("f", 0)
        self.assertIsNone(groups.record("f", 10))

        groups.rollback(attempt)

        self.assertEqual({"fingerprint": "f", "count": 3, "first_seen": 0, "last_seen": 11},
                         groups.record("f", 11))

    def test_only_max_groups_completed_fingerprints_are_remembered(self):
        groups = Groups(60)
        for i in range(pocket_kit.MAX_GROUPS + 1):
            attempt = groups.record("f%d" % i, 0)
            groups.commit(attempt, 0)
        self.assertIsNotNone(groups.record("f0", 0))
        self.assertIsNone(groups.record("f%d" % pocket_kit.MAX_GROUPS, 0))

    def test_failed_groups_are_bounded_and_the_oldest_can_be_retried_as_new(self):
        groups = Groups(60)
        for i in range(pocket_kit.MAX_GROUPS + 1):
            attempt = groups.record("f%d" % i, 0)
            groups.rollback(attempt)

        self.assertEqual(1, groups.record("f0", 1)["count"])
        self.assertEqual(2, groups.record("f%d" % pocket_kit.MAX_GROUPS, 1)["count"])

    def test_an_active_group_is_not_evicted_to_enforce_the_inactive_group_limit(self):
        groups = Groups(60)
        active = groups.record("active", 0)
        for i in range(pocket_kit.MAX_GROUPS):
            attempt = groups.record("f%d" % i, 0)
            groups.commit(attempt, 0)

        self.assertIsNone(groups.record("active", 1))
        groups.rollback(active)
        self.assertEqual(3, groups.record("active", 2)["count"])


if __name__ == "__main__":
    unittest.main()
