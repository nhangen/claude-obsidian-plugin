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
(case / 'provider-input').write_text(sys.stdin.read())
if os.environ.get('BLOCK_PROVIDER') == '1':
    (case / 'ready').touch()
    deadline = time.monotonic() + 15
    while not (case / 'release').exists():
        if time.monotonic() > deadline:
            sys.exit(99)
        time.sleep(0.01)
if os.environ.get('AUTOSAVE_CONTEXT_FILE'):
    (case / 'context-copy').write_text(pathlib.Path(os.environ['AUTOSAVE_CONTEXT_FILE']).read_text())
if os.environ.get('DROP_RECEIPT') == '1':
    pathlib.Path(os.environ['AUTOSAVE_SENT_FILE']).unlink()
if os.environ.get('FAIL_PROVIDER') == '1':
    print('sensitive provider error must never enter receipts', file=sys.stderr)
    sys.exit(23)
note = ("---\\ndate: 2026-10-18\\ndomain: dev\\nvault_folder: Inbox/\\nslug: gate-fixture\\n"
        "session_intent: execution\\ncapture_action: project_note\\nresearch_state_change: none\\n---\\n\\n"
        "# Gate fixture\\n\\n## Summary\\n- fixture\\n")
print(json.dumps({"type":"result", "subtype":"success", "is_error":False,
                  "result": note if os.environ.get('PROVIDER_NOTE') == '1' else "SKIP"}))
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
                               "keeper_autostart: false\nsummary_interval_secs: 0\nsummary_min_messages: 1\n---\n")

    def message(self, uuid, text):
        with self.transcript.open("a") as stream:
            stream.write(json.dumps({"type": "assistant", "uuid": uuid,
                                     "message": {"role": "assistant", "content": [
                                         {"type": "text", "text": text}]}}) + "\n")

    def start(self, *args, session="fixture-session", **env):
        payload = {"transcript_path": str(self.transcript), "session_id": session, "cwd": str(self.case / "repo")}
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

    def automatic_defaults(self):
        self.config.write_text(self.config.read_text().replace(
            "summary_interval_secs: 0", "summary_interval_secs: 900").replace(
            "summary_min_messages: 1", "summary_min_messages: 3"))

    def test_routine_stops_do_not_invoke_provider(self):
        self.transcript.write_text("")
        self.message("ack", "Thanks, that makes sense.")
        self.message("question", "What changed?")
        self.run_hook()
        self.assertFalse(self.calls())
        self.assertFalse(self.receipts())

    def test_research_batches_without_git_then_cooldown_preserves_pending(self):
        self.automatic_defaults()
        self.run_hook()
        self.assertFalse(self.calls())
        self.message("second", "Research observation: the evidence is incomplete and the source needs verification. " * 2)
        self.run_hook()
        self.assertFalse(self.calls())
        self.message("third", "Research decision: preserve the uncertainty and compare the competing explanations. " * 2)
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        self.message("fourth", "A further research finding changes the interpretation of the previous comparison. " * 2)
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        self.run_hook("--capture")
        self.assertEqual(len(self.calls()), 2)
        self.assertIn("further research finding", (self.case / "provider-input").read_text())

    def test_git_changes_qualify_and_successful_capture_uses_only_new_activity(self):
        self.automatic_defaults()
        repo = self.case / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
                        "commit", "--allow-empty", "-m", "Fixture baseline"],
                       check=True, capture_output=True)
        (repo / "changed.txt").write_text("fixture change")
        (repo / "API_KEY=fictional-git-secret.txt").write_text("credential-shaped filename")
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        payload = (self.case / "provider-input").read_text()
        self.assertIn("local_git_evidence", payload)
        self.assertIn("changed.txt", payload)
        self.assertNotIn("fictional-git-secret", payload)
        self.assertIn("not proof of authorship", payload)
        context = (self.case / "context-copy").read_text()
        self.assertIn("changed.txt", context)
        self.assertNotIn("fictional-git-secret", context)
        self.assertFalse(list((self.case / "state").glob("**/context-*.json")))
        # Expire the checkpoint without sleeping or introducing a production clock override.
        state, = (self.case / "state").glob("**/activity.json")
        checkpoint = json.loads(state.read_text())
        checkpoint["last_attempt"] = 0
        state.write_text(json.dumps(checkpoint))
        self.message("second", "The dirty Git state is unchanged, so one intermediate response must not trigger a call. " * 2)
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        for uuid in ("third", "fourth"):
            self.message(uuid, "New research without another repository change still deserves a later checkpoint. " * 2)
        self.run_hook()
        self.assertEqual(len(self.calls()), 2)
        payload = (self.case / "provider-input").read_text()
        self.assertNotIn("Decided to preserve the validated result", payload)
        self.assertIn("New research", payload)
        checkpoint = json.loads(state.read_text())
        checkpoint["last_attempt"] = 0
        state.write_text(json.dumps(checkpoint))
        subprocess.run(["git", "-C", str(repo), "add", "changed.txt"], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
                        "commit", "-m", "Fixture checkpoint commit"], check=True, capture_output=True)
        self.message("after-commit", "A committed result must still qualify even though the working tree is now clean. " * 2)
        self.run_hook()
        self.assertEqual(len(self.calls()), 3)
        self.assertIn("Fixture checkpoint commit", (self.case / "provider-input").read_text())

    def test_failed_call_keeps_unsummarized_activity(self):
        self.run_hook(FAIL_PROVIDER="1")
        self.message("second", "New evidence after the failure must not discard earlier unsummarized decisions. " * 2)
        self.run_hook()
        self.assertEqual(len(self.calls()), 2)
        self.assertIn("Decided to preserve", (self.case / "provider-input").read_text())

    def test_different_boundaries_share_in_flight_session_lock(self):
        first = self.start(BLOCK_PROVIDER="1")
        self.wait_for(lambda: (self.case / "ready").exists())
        self.message("second", "A second changed boundary while capture is running must not start another model. " * 2)
        self.finish(self.start())
        self.assertEqual(len(self.calls()), 1)
        (self.case / "release").touch()
        self.finish(first)
        self.run_hook()
        self.assertEqual(len(self.calls()), 2)

    def expire(self):
        state, = (self.case / "state").glob("**/activity.json")
        checkpoint = json.loads(state.read_text())
        checkpoint["last_attempt"] = 0
        state.write_text(json.dumps(checkpoint))

    def seen_count(self):
        state, = (self.case / "state").glob("**/activity.json")
        return len(json.loads(state.read_text()).get("seen", []))

    def provider_rows(self):
        return [json.loads(line) for line in (self.case / "provider-input").read_text().splitlines()]

    def provider_text(self):
        return "\n".join(row.get("text", "") for row in self.provider_rows()[1:])

    def fill(self, prefix, count, size):
        for i in range(count):
            self.message(f"{prefix}{i}", f"{prefix}{i} " + "note " * (size // 5))

    def test_automatic_input_is_bounded_redacted_and_preserves_original(self):
        for i in range(16):
            self.message(str(i), "Decision head " + "🦉" * 4000 + " API_KEY=fictional-automatic-secret tail evidence")
        original = self.transcript.read_bytes()
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(original, self.transcript.read_bytes())
        payload = (self.case / "provider-input").read_text()
        metadata = json.loads(payload.splitlines()[0])
        self.assertLessEqual(metadata["payload_bytes"], 65536)
        self.assertGreater(metadata["source_bytes"], len(original) - 1)
        self.assertNotIn("local_activity_digest", payload)
        self.assertNotIn("fictional-automatic-secret", payload)
        self.assertIn("[REDACTED]", payload)
        state = "".join(p.read_text() for p in (self.case / "state").glob("**/*.json"))
        self.assertNotIn("Decision head", state)
        self.assertNotIn("tail evidence", state)

    def test_older_pending_event_and_middle_of_long_event_reach_the_model(self):
        self.transcript.write_text("")
        self.message("old", "OLD-DECISION-A: accepted finding, dropped finding two. " + "note " * 60)
        self.message("long", "LONG-HEAD " + "alpha " * 1500 + " MIDDLE-FACT-B exact test outcome PASS on php 8.3 " + "beta " * 1800 + " LONG-TAIL")
        self.fill("filler", 20, 400)
        self.run_hook(PROVIDER_NOTE="1")
        text = self.provider_text()
        for fact in ("OLD-DECISION-A", "MIDDLE-FACT-B", "LONG-TAIL", "filler19"):
            self.assertIn(fact, text)
        metadata = self.provider_rows()[0]
        self.assertFalse(metadata["context_incomplete"])
        self.assertEqual(metadata["retained_events"], 0)
        self.assertEqual(self.seen_count(), 22)
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture.md")
        self.assertIn('"context_incomplete":false', note.read_text())

    def test_omitted_pending_stays_unacknowledged_and_is_sent_next_capture(self):
        self.transcript.write_text("")
        for i in range(14):
            self.message(f"big{i}", f"FACT-{i:02d} " + "note " * 1400)
        self.run_hook(PROVIDER_NOTE="1")
        first = self.provider_text()
        metadata = self.provider_rows()[0]
        self.assertTrue(metadata["context_incomplete"])
        self.assertGreater(metadata["retained_events"], 0)
        self.assertIn("FACT-00", first)
        self.assertNotIn("FACT-13", first)
        self.assertEqual(self.seen_count(), metadata["sent_events"])
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture.md")
        self.assertIn('"context_incomplete":true', note.read_text())
        self.expire()
        self.message("later", "later " + "note " * 100)
        self.run_hook()
        self.assertEqual(len(self.calls()), 2)
        second = self.provider_text()
        self.assertIn("FACT-13", second)
        self.assertNotIn("FACT-00", second)
        self.assertEqual(self.seen_count(), 15)

    def test_skip_acknowledges_only_events_the_model_received(self):
        self.transcript.write_text("")
        self.fill("skipped", 14, 7000)
        self.run_hook()
        metadata = self.provider_rows()[0]
        self.assertGreater(metadata["retained_events"], 0)
        self.assertEqual(self.seen_count(), metadata["sent_events"])
        self.assertFalse(list((self.case / "vault").glob("**/*gate-fixture.md")))

    def test_oversized_event_is_clipped_flagged_and_acknowledged(self):
        self.transcript.write_text("")
        self.message("huge", "HUGE-HEAD " + "note " * 9000 + " HUGE-TAIL")
        self.fill("small", 3, 500)
        self.run_hook()
        metadata = self.provider_rows()[0]
        self.assertEqual(metadata["omissions"]["clipped_events"], 1)
        self.assertTrue(metadata["context_incomplete"])
        self.assertIn("HUGE-TAIL", self.provider_text())
        self.assertEqual(self.seen_count(), 4)

    def test_missing_sent_receipt_acknowledges_nothing_and_is_recorded(self):
        self.transcript.write_text("")
        self.fill("dropped", 4, 500)
        self.run_hook(DROP_RECEIPT="1")
        self.assertEqual(self.seen_count(), 0)
        self.assertEqual({r["ack"] for r in self.receipts()}, {"receipt_missing"})

    def test_forced_capture_over_budget_acknowledges_only_what_was_sent(self):
        self.transcript.write_text("")
        for i in range(14):
            self.message(f"big{i}", f"FACT-{i:02d} " + "note " * 1400)
        self.run_hook("--capture")
        metadata = self.provider_rows()[0]
        self.assertFalse(metadata["carry_forward"])
        self.assertTrue(metadata["context_incomplete"])
        self.assertLess(metadata["sent_events"], 14)
        self.assertEqual(self.seen_count(), metadata["sent_events"])
        self.assertIn("FACT-13", self.provider_text())
        self.assertNotIn("FACT-00", self.provider_text())

    def test_failed_capture_acknowledges_nothing(self):
        self.transcript.write_text("")
        self.fill("failed", 6, 500)
        self.run_hook(FAIL_PROVIDER="1")
        self.assertEqual(self.seen_count(), 0)
        self.expire()
        self.message("later", "later " + "note " * 100)
        self.run_hook()
        self.assertEqual(len(self.calls()), 2)
        self.assertIn("failed0", self.provider_text())
        self.assertEqual(self.seen_count(), 7)

    def test_compaction_and_rewrite_resend_only_what_changed(self):
        self.transcript.write_text("")
        self.fill("before", 4, 500)
        self.run_hook()
        self.expire()
        with self.transcript.open("a") as stream:
            stream.write(json.dumps({"type": "user", "isCompactSummary": True, "uuid": "compact",
                                     "message": {"role": "user", "content": "COMPACT-SUMMARY decision carried forward " + "s" * 200}}) + "\n")
        self.fill("after", 3, 500)
        self.run_hook()
        text = self.provider_text()
        self.assertIn("COMPACT-SUMMARY", text)
        self.assertIn("after0", text)
        self.assertNotIn("before0", text)
        self.assertEqual(self.provider_rows()[0]["mode"], "previous_summary_plus_delta")
        self.expire()
        self.message("after1", "after1 " + "note " * 100 + " REWRITTEN-CONCLUSION")
        self.message("after-extra", "after-extra " + "note " * 100)
        self.message("after-extra2", "after-extra2 " + "note " * 100)
        self.run_hook()
        text = self.provider_text()
        self.assertIn("REWRITTEN-CONCLUSION", text)
        self.assertNotIn("after2 ", text)

    def test_invalid_activity_configuration_and_state_fail_closed(self):
        self.config.write_text(self.config.read_text().replace("summary_interval_secs: 0", "summary_interval_secs: typo"))
        self.run_hook()
        self.assertFalse(self.calls())
        self.configure()
        self.run_hook()
        state, = (self.case / "state").glob("**/activity.json")
        state.write_text("[]")
        self.message("second", "New evidence with corrupt activity state must never silently bypass the gate. " * 2)
        self.run_hook()
        self.assertEqual(len(self.calls()), 1)

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
        self.message("second", "Final commit abc1234 passed the regression fixture. The local mock-data checks passed and the result was recorded.")
        self.run_hook()
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(len(self.receipts()), 2)
        self.message("second", "Corrected the final result: the live rollout is still unverified. Only local mock-data checks were run and passed.")
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
