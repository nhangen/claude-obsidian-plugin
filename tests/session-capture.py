import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SessionCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="obsidian-capture-test-")
        self.addCleanup(self.temp.cleanup)
        self.case = Path(self.temp.name)
        for directory in ("home", "bin", "vault", "tmp"):
            (self.case / directory).mkdir()
        self.config = self.case / "config.md"
        self.configure()
        self.transcript = self.case / "parent.jsonl"
        self.message("first", "Decided to preserve the validated result. " * 6)
        provider = self.case / "bin/claude"
        provider.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys, time
case = pathlib.Path(os.environ['CAPTURE_CASE'])
with (case / 'calls').open('a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
sys.stdin.read()
if os.environ.get('BLOCK_PROVIDER') == '1':
    (case / 'ready').touch()
    deadline = time.monotonic() + 15
    while not (case / 'release').exists():
        if time.monotonic() > deadline:
            sys.exit(99)
        time.sleep(0.01)
if os.environ.get('FAIL_PROVIDER') == '1':
    print('sensitive provider error must never enter receipts', file=sys.stderr)
    sys.exit(23)
print(json.dumps({"type":"result", "subtype":"success", "is_error":False, "result":"SKIP"}))
""")
        provider.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.case / "home"),
                        XDG_CONFIG_HOME=str(self.case / "home/.config"),
                        XDG_STATE_HOME=str(self.case / "state"),
                        XDG_CACHE_HOME=str(self.case / "cache"),
                        TMPDIR=str(self.case / "tmp"),
                        PATH=f"{self.case}/bin:{os.environ['PATH']}",
                        OBSIDIAN_LOCAL_MD=str(self.config),
                        CAPTURE_CASE=str(self.case), ANTHROPIC_API_KEY="",
                        OBSIDIAN_SUMMARIZING="")

    def configure(self, capture="stop", auto_save="true"):
        self.config.write_text(f"---\nvault_path: {self.case}/vault\n"
                               f"auto_save: {auto_save}\nsummary_capture: {capture}\n"
                               "keeper_autostart: false\n---\n")

    def message(self, uuid, text):
        with self.transcript.open("a") as stream:
            stream.write(json.dumps({"type": "assistant", "uuid": uuid,
                                     "message": {"role": "assistant", "content": [
                                         {"type": "text", "text": text}]}}) + "\n")

    def start(self, *args, session="fixture-session", **env):
        payload = {"transcript_path": str(self.transcript), "session_id": session}
        process = subprocess.Popen(
            ["bash", "-c", 'trap wait EXIT; source "$0" "$@"',
             str(ROOT / "scripts/session-save.sh"), *args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(self.env, **env))
        process.stdin.write(json.dumps(payload))
        process.stdin.close()
        process.stdin = None
        self.addCleanup(self.reap, process)
        return process

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=20)

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, (stdout, stderr))
        return stderr

    def run_hook(self, *args, **kwargs):
        return self.finish(self.start(*args, **kwargs))

    def calls(self):
        path = self.case / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def receipts(self):
        return [json.loads(p.read_text()) for p in
                (self.case / "state").glob("**/boundaries/*.json")]

    def wait_for(self, predicate):
        deadline = time.monotonic() + 10
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("capture fixture did not reach synchronization point")
            time.sleep(0.01)

    def test_paired_hooks_and_late_instrumentation_summarize_once(self):
        first = self.start(BLOCK_PROVIDER="1")
        self.wait_for(lambda: (self.case / "ready").exists())
        repeated_message = self.transcript.read_text().splitlines()[0]
        with self.transcript.open("a") as stream:
            stream.write(json.dumps({"type": "progress", "data": "hook bookkeeping"}) + "\n")
            stream.write(repeated_message + "\n")
        second = self.start()
        self.finish(second)
        self.assertEqual(len(self.calls()), 1)
        (self.case / "release").touch()
        self.finish(first)
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        receipt, = self.receipts()
        self.assertEqual(receipt["status"], "process_succeeded")
        self.assertIsNone(receipt["provider_success"])
        self.assertIsNone(receipt["usage"])
        usage_path, = (self.case / "state/obsidian/summary-usage").glob("*.json")
        usage = json.loads(usage_path.read_text())
        self.assertEqual(usage["source_session_hash"], hashlib.sha256(str(self.transcript).encode()).hexdigest())
        self.assertEqual(usage["attempts"], 1)
        self.assertEqual(usage["successful_calls"], 1)
        self.assertEqual(usage["dedup_outcome"], "skipped")


    def test_new_message_boundary_is_not_suppressed(self):
        self.run_hook()
        self.message("second", "Final commit abc1234 passed the regression fixture.")
        self.run_hook()
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(len(self.receipts()), 2)
        self.message("second", "Corrected the final result: the live rollout is still unverified.")
        self.run_hook()
        self.assertEqual(len(self.calls()), 3)

    def test_failed_boundary_requires_deliberate_retry(self):
        self.run_hook(FAIL_PROVIDER="1")
        receipt, = self.receipts()
        self.assertEqual(receipt["status"], "process_failed")
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        self.run_hook("--retry")
        self.assertEqual(len(self.calls()), 2)
        receipt, = self.receipts()
        self.assertEqual(receipt["status"], "process_succeeded")
        self.assertEqual(receipt["attempt"], 2)
        state = "".join(p.read_text() for p in (self.case / "state").glob("**/*.json"))
        self.assertNotIn("sensitive provider error", state)
        self.assertNotIn("Decided to preserve", state)
        for path in (self.case / "state").glob("**/*.json"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_crashed_worker_keeps_child_claim_and_requires_retry(self):
        first = self.start(BLOCK_PROVIDER="1")
        self.wait_for(lambda: (self.case / "ready").exists())
        receipt, = self.receipts()
        os.kill(receipt["worker_pid"], signal.SIGKILL)
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        (self.case / "release").touch()
        self.finish(first)
        lock_path, = (self.case / "state").glob("**/boundaries/*.lock")

        def child_released_lock():
            with lock_path.open() as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return False
                return True

        self.wait_for(child_released_lock)
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        receipt, = self.receipts()
        self.assertEqual(receipt["status"], "interrupted")
        self.run_hook("--retry")
        self.assertEqual(len(self.calls()), 2)

    def test_explicit_mode_and_opt_out_preserve_manual_capture(self):
        self.configure(capture="explicit")
        self.run_hook()
        self.assertFalse(self.calls())
        self.run_hook("--capture")
        self.assertEqual(len(self.calls()), 1)
        self.configure(capture="stop", auto_save="false")
        self.message("second", "Manual checkpoint after disabling automatic saves.")
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        self.run_hook("--capture")
        self.assertEqual(len(self.calls()), 2)

    def test_unknown_mode_fails_closed(self):
        for mode in ("explict", ""):
            with self.subTest(mode=mode):
                self.configure(capture=mode)
                stderr = self.run_hook()
                self.assertFalse(self.calls())
                self.assertIn("summary_capture", stderr)

    def test_missing_session_id_uses_transcript_identity(self):
        self.run_hook(session="")
        self.run_hook(session="")
        self.assertEqual(len(self.calls()), 1)
        other = self.case / "other.jsonl"
        other.write_bytes(self.transcript.read_bytes())
        self.transcript = other
        self.run_hook(session="")
        self.assertEqual(len(self.calls()), 2)

    def test_malformed_transcript_and_corrupt_receipt_do_not_dispatch(self):
        original = self.transcript.read_bytes()
        self.transcript.write_bytes(original + b'{"type":"assistant",')
        self.run_hook()
        self.assertFalse(self.calls())
        self.transcript.write_bytes(original)
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        receipt_path, = (self.case / "state").glob("**/boundaries/*.json")
        receipt_path.write_text('{"status":"unknown"}')
        self.run_hook("--retry")
        self.assertEqual(len(self.calls()), 1)
        event_path, = (self.case / "state").glob("**/last-event.json")
        self.assertEqual(json.loads(event_path.read_text())["status"], "invalid_receipt")

    def test_source_identity_is_private_and_scoped_to_vault(self):
        session = "private-source-session-identifier"
        self.run_hook(session=session)
        state = "".join(p.read_text() for p in (self.case / "state").glob("**/*.json"))
        self.assertNotIn(session, state)
        self.assertNotIn(str(self.transcript), state)
        other_vault = self.case / "other-vault"
        other_vault.mkdir()
        self.config.write_text(self.config.read_text().replace(
            f"vault_path: {self.case}/vault", f"vault_path: {other_vault}"))
        self.run_hook(session=session)
        self.assertEqual(len(self.calls()), 2)

    def test_unusable_state_reports_sanitized_error_before_dispatch(self):
        unavailable = self.case / "state-file-sensitive-fixture"
        unavailable.write_text("not a directory")
        self.env["XDG_STATE_HOME"] = str(unavailable)
        for args in ((), ("--capture",), ("--retry",)):
            with self.subTest(args=args):
                stderr = self.run_hook(*args)
                self.assertIn("cannot initialize capture state", stderr)
                self.assertIn("XDG_STATE_HOME", stderr)
                self.assertNotIn(str(unavailable), stderr)
                self.assertNotIn("Traceback", stderr)
                self.assertNotIn("Decided to preserve", stderr)
                self.assertFalse(self.calls())
                self.assertFalse(self.receipts())
                self.assertFalse(list((self.case / "tmp").glob("obsidian-session-*")))

    def test_preflight_does_not_wait_for_background_capture(self):
        process = subprocess.Popen(
            ["bash", str(ROOT / "scripts/session-save.sh")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(self.env, BLOCK_PROVIDER="1"))
        self.addCleanup(self.reap, process)
        try:
            stdout, stderr = process.communicate(json.dumps({
                "transcript_path": str(self.transcript), "session_id": "async-fixture"}), timeout=5)
            self.assertEqual(process.returncode, 0, (stdout, stderr))
            self.wait_for(lambda: (self.case / "ready").exists())
            receipt, = self.receipts()
            self.assertEqual(receipt["status"], "running")
        finally:
            (self.case / "release").touch()
            self.wait_for(lambda: any(r["status"] == "process_succeeded" for r in self.receipts()))


if __name__ == "__main__":
    unittest.main()
