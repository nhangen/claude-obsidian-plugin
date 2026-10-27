import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock


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
payload = sys.stdin.read()
(case / 'provider-input').write_text(payload)
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
if os.environ.get('NOTE_DELIVERED_FACTS') == '1':
    facts = [row['text'].split()[0] for row in map(json.loads, payload.splitlines())
             if row.get('text', '').startswith('FACT-')]
    note += ''.join('- delivered: ' + fact + '\\n' for fact in facts)
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

    def start(self, *args, session="fixture-session", script=None, **env):
        payload = {"transcript_path": str(self.transcript), "session_id": session, "cwd": str(self.case / "repo")}
        process = subprocess.Popen(
            ["bash", "-c", 'trap wait EXIT; source "$0" "$@"',
             str(script or ROOT / "scripts/session-save.sh"), *args],
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
        lock_path = self.case / "state/claude-obsidian/capture-ownership/admission.lock"
        provider_blocked = (self.case / "ready").exists() and not (self.case / "release").exists()
        if lock_path.exists() and not provider_blocked:
            def completed():
                with lock_path.open("r+") as stream:
                    try:
                        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        return True
                    except BlockingIOError:
                        return False
            self.wait_for(completed)
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

    def assert_deferred_observation_blocks_handoff(self, interval, minimum, count, expected):
        repo = self.case / "repo"
        subprocess.run(["git", "init", "-q", str(repo)], env=self.env, check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
                        "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "Baseline"],
                       env=self.env, check=True)
        self.run_hook(PROVIDER_NOTE="1")
        activity, = (self.case / "state").glob("**/activity.json")
        acknowledged = json.loads(activity.read_text())
        self.assertIsNotNone(acknowledged["git"])
        self.assertEqual(len(acknowledged["head"]), 40)
        self.config.write_text(self.config.read_text().replace(
            "summary_interval_secs: 0", f"summary_interval_secs: {interval}").replace(
            "summary_min_messages: 1", f"summary_min_messages: {minimum}"))
        for index in range(count):
            self.message(f"deferred-{index}", f"Pending research finding {index}: " + "new evidence " * 12)
        self.run_hook(PROVIDER_NOTE="1")
        last, = (self.case / "state").glob("**/last-event.json")
        self.assertEqual(json.loads(last.read_text())["status"], expected)
        observed = json.loads(activity.read_text())
        self.assertEqual(len(observed.get("pending", [])), count)
        self.assertEqual({k: v for k, v in observed.items() if k != "pending"},
                         {k: v for k, v in acknowledged.items() if k != "pending"})
        self.assertEqual(len(self.calls()), 1)
        self.run_hook(PROVIDER_NOTE="1")
        self.assertEqual(json.loads(activity.read_text()), observed)
        result = subprocess.run(
            ["python3", str(ROOT / "scripts/lib/capture-owner.py"), "handoff", "--owner", "disabled",
             "--verification", "legacy-writers-stopped-and-history-inspected"],
            env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("legacy activity", result.stderr)
        self.assertEqual(json.loads(activity.read_text()), observed)

    def test_deferred_interval_observations_block_handoff_after_success(self):
        self.assert_deferred_observation_blocks_handoff(900, 1, 3, "deferred_interval")

    def test_deferred_activity_observations_block_handoff_after_success(self):
        self.assert_deferred_observation_blocks_handoff(0, 3, 1, "deferred_activity")

    def test_rewritten_transcript_cannot_acknowledge_omitted_deferred_evidence(self):
        self.run_hook(PROVIDER_NOTE="1")
        original = self.transcript.read_bytes()
        self.config.write_text(self.config.read_text().replace(
            "summary_interval_secs: 0", "summary_interval_secs: 900"))
        self.message("omitted", "An unacknowledged decision before a rewrite. " * 8)
        self.run_hook()
        activity, = (self.case / "state").glob("**/activity.json")
        omitted = json.loads(activity.read_text())["pending"]
        self.assertEqual(len(omitted), 1)
        self.transcript.write_bytes(original)
        self.message("replacement", "New information after the transcript was rewritten. " * 8)
        self.run_hook("--capture", PROVIDER_NOTE="1")
        self.assertTrue(set(omitted).issubset(json.loads(activity.read_text())["pending"]))
        result = subprocess.run(
            ["python3", str(ROOT / "scripts/lib/capture-owner.py"), "handoff", "--owner", "disabled",
             "--verification", "legacy-writers-stopped-and-history-inspected"],
            env=self.env, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)

    def test_eligible_observation_survives_preparation_failure_before_receipt(self):
        repo = self.case / "repo"
        subprocess.run(["git", "init", "-q", str(repo)], env=self.env, check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "Baseline"],
                       env=self.env, check=True)
        self.run_hook(PROVIDER_NOTE="1")
        self.message("new-eligible", "A meaningful new decision must remain pending if preparation fails. " * 4)
        scripts = self.case / "copied-scripts"
        shutil.copytree(ROOT / "scripts", scripts)
        counter = self.case / "redaction-count"
        counter.write_text("0")
        (scripts / "lib/redact-secrets.sh").write_text('''#!/usr/bin/env bash
set -euo pipefail
count=$(<"${REDACTION_CALL_COUNT:?}")
count=$((count + 1))
printf '%s' "$count" > "$REDACTION_CALL_COUNT"
[ "$count" -ne 2 ] || exit 23
exec bash "${REAL_REDACTOR:?}" "$@"
''')
        self.run_hook(script=scripts / "session-save.sh", PROVIDER_NOTE="1", REDACTION_CALL_COUNT=str(counter),
                      REAL_REDACTOR=str(ROOT / "scripts/lib/redact-secrets.sh"))
        last, = (self.case / "state").glob("**/last-event.json")
        self.assertEqual(json.loads(last.read_text())["status"], "redaction_error")
        self.assertEqual(len(self.calls()), 1)
        activity, = (self.case / "state").glob("**/activity.json")
        self.assertTrue(all(receipt["status"] == "process_succeeded" for receipt in self.receipts()))
        result = subprocess.run(["python3", str(ROOT / "scripts/lib/capture-owner.py"), "handoff", "--owner", "disabled",
                                 "--verification", "legacy-writers-stopped-and-history-inspected"],
                                env=self.env, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(json.loads(activity.read_text())["pending"]), 1)

    def test_unstarted_launch_cannot_pass_handoff(self):
        prepared = subprocess.run(["python3", str(ROOT / "scripts/lib/session-capture.py"), "--prepare",
                                   str(self.case / "vault"), str(self.transcript), "fixture-session"],
                                  env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(len(prepared.stdout.strip()), 32)
        launch, = (self.case / "state").glob("**/launches/*.json")
        self.assertEqual(json.loads(launch.read_text())["status"], "prepared")
        refused = subprocess.run(["python3", str(ROOT / "scripts/lib/capture-owner.py"), "handoff", "--owner", "disabled",
                                  "--verification", "legacy-writers-stopped-and-history-inspected"],
                                 env=self.env, capture_output=True)
        self.assertNotEqual(refused.returncode, 0)

    def test_busy_new_boundary_remains_pending_after_older_capture_finishes(self):
        first = self.start(BLOCK_PROVIDER="1", PROVIDER_NOTE="1")
        self.wait_for(lambda: (self.case / "ready").exists())
        self.message("busy-new", "New meaningful evidence arrived while another capture held the activity lock. " * 4)
        self.finish(self.start(PROVIDER_NOTE="1"))
        (self.case / "release").touch()
        self.finish(first)
        launches = [json.loads(path.read_text()) for path in (self.case / "state").glob("**/launches/*.json")]
        self.assertTrue(any(record["status"] == "deferred_busy" for record in launches))
        owner = ["python3", str(ROOT / "scripts/lib/capture-owner.py")]
        refused = subprocess.run(owner + ["handoff", "--owner", "disabled", "--verification",
                                         "legacy-writers-stopped-and-history-inspected"],
                                 env=self.env, capture_output=True)
        self.assertNotEqual(refused.returncode, 0)
        subprocess.run(owner + ["resume"], env=self.env, check=True, capture_output=True)
        self.run_hook(PROVIDER_NOTE="1")
        self.assertEqual(len(self.calls()), 2)
        settled = subprocess.run(owner + ["handoff", "--owner", "disabled", "--verification",
                                         "legacy-writers-stopped-and-history-inspected"],
                                 env=self.env, capture_output=True)
        self.assertEqual(settled.returncode, 0, settled.stderr)

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
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
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
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
        self.assertIn('"context_incomplete":true', note.read_text())
        activity, = (self.case / "state").glob("**/activity.json")
        retained = json.loads(activity.read_text())
        self.config.write_text(self.config.read_text().replace(
            "summary_interval_secs: 0", "summary_interval_secs: 900"))
        self.message("later", "later " + "note " * 100)
        self.run_hook()
        deferred = json.loads(activity.read_text())
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue(set(retained["pending"]).issubset(deferred["pending"]))
        self.assertEqual(len(deferred["pending"]), len(retained["pending"]) + 1)
        self.assertEqual(deferred["seen"], retained["seen"])
        self.assertEqual(deferred["last_attempt"], retained["last_attempt"])
        self.expire()
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
        self.assertFalse(list((self.case / "vault").glob("**/*gate-fixture*.md")))

    def test_corrupt_checkpoint_pointer_preserves_unacknowledged_activity(self):
        self.run_hook(PROVIDER_NOTE="1")
        pointer, = (self.case / "state/claude-obsidian/summary-notes").glob("*.json")
        original = pointer.read_text()
        seen = self.seen_count()
        pointer.write_text("broken json")
        self.message("later", "Important later decision: preserve checkpoint retry evidence. " * 5)
        self.run_hook(PROVIDER_NOTE="1")
        self.assertEqual(self.seen_count(), seen)
        self.assertIn("process_failed", {r["status"] for r in self.receipts()})
        outcomes = {json.loads(p.read_text()).get("dedup_outcome")
                    for p in (self.case / "state/obsidian/summary-usage").glob("*.json")}
        self.assertIn("state_invalid", outcomes)
        pointer.write_text(original)
        self.run_hook("--retry", PROVIDER_NOTE="1")
        self.assertGreater(self.seen_count(), seen)
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
        self.assertEqual(note.read_text().count("## Checkpoint "), 2)

    def test_later_checkpoint_appends_without_replacing_earlier_evidence(self):
        self.run_hook(PROVIDER_NOTE="1")
        note, = (self.case / "vault/Inbox").glob("*gate-fixture*.md")
        first = note.read_text()
        self.message("later", "Later decision: preserve previous checkpoints rather than replace them. " * 5)
        self.run_hook(PROVIDER_NOTE="1")
        self.assertTrue(note.read_text().startswith(first))
        self.assertEqual(note.read_text().count("## Checkpoint "), 2)
        self.assertEqual(len(list((self.case / "vault/Inbox").glob("*gate-fixture*.md"))), 1)

    def test_checkpoint_pointer_recovery_does_not_duplicate_first_save(self):
        self.run_hook(PROVIDER_NOTE="1")
        pointer, = (self.case / "state/claude-obsidian/summary-notes").glob("*.json")
        state = json.loads(pointer.read_text())
        state["ready"] = False
        pointer.write_text(json.dumps(state))
        self.message("later", "Another durable decision: repair the saved pointer before acknowledging. " * 5)
        self.run_hook(PROVIDER_NOTE="1")
        self.assertTrue(json.loads(pointer.read_text())["ready"])
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
        self.assertEqual(note.read_text().count("## Checkpoint "), 2)
        daily, = (self.case / "vault/Daily").glob("*.md")
        self.assertEqual(daily.read_text().count(note.stem), 1)

    def test_deleted_canonical_note_is_recreated_by_the_next_checkpoint(self):
        self.run_hook(PROVIDER_NOTE="1")
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
        note.unlink()
        self.message("later", "Durable decision: recreate a deleted checkpoint log instead of wedging autosave. " * 5)
        self.run_hook(PROVIDER_NOTE="1")
        recreated, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
        self.assertEqual(recreated, note)
        self.assertEqual(note.read_text().count("## Checkpoint "), 1)
        self.assertNotIn("process_failed", {r["status"] for r in self.receipts()})
        daily, = (self.case / "vault/Daily").glob("*.md")
        self.assertEqual(daily.read_text().count(note.stem), 1)

    def test_checkpoint_failure_names_the_reason_without_leaking_paths(self):
        helper = ROOT / "scripts/lib/summary-note.py"
        secret = self.case / "sensitive-missing-vault"
        for vault, reason, code in (("", "missing vault", 4), (str(secret), "FileNotFoundError", 1)):
            with self.subTest(reason=reason):
                result = subprocess.run(
                    ["python3", str(helper), vault, "source", "Inbox/x.md", "body", "t", "2026-01-01",
                     "Daily", "usage", "input"],
                    capture_output=True, text=True, env=self.env, check=False)
                self.assertEqual(result.returncode, code)
                self.assertIn(f"checkpoint write failed ({reason})", result.stderr)
                self.assertNotIn(str(secret), result.stderr)

    def test_model_frontmatter_cannot_duplicate_reserved_checkpoint_keys(self):
        spec = importlib.util.spec_from_file_location("summary_note", ROOT / "scripts/lib/summary-note.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cleaned = module.without_reserved_keys(
            "session_intent: execution\ncapture_scope: model_guess\ncheckpoint_source_key: abc\nslug: x")
        self.assertEqual(cleaned, "session_intent: execution\nslug: x")

    def test_checkpoint_symlink_does_not_write_or_acknowledge(self):
        self.run_hook(PROVIDER_NOTE="1")
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
        outside = self.case / "outside.md"
        outside.write_text("must not change")
        note.unlink()
        note.symlink_to(outside)
        seen = self.seen_count()
        self.message("later", "Never follow a replaced checkpoint symlink while saving evidence. " * 5)
        self.run_hook(PROVIDER_NOTE="1")
        self.assertEqual(self.seen_count(), seen)
        self.assertEqual(outside.read_text(), "must not change")
        self.assertIn("process_failed", {r["status"] for r in self.receipts()})

    def test_invalid_vault_refuses_before_provider_or_note_writes(self):
        unavailable = self.case / "unavailable-vault"
        unavailable.write_text("not a directory")
        for name, vault in (("missing", str(self.case / "missing-vault")),
                            ("unavailable", str(unavailable)), ("empty", "")):
            with self.subTest(vault=name):
                working = self.case / name
                working.mkdir()
                snapshot = working / "snapshot.jsonl"
                snapshot.write_bytes(self.transcript.read_bytes())
                before = set(self.case.rglob("*.md"))
                calls = len(self.calls())
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/session-summarize.sh"),
                     str(snapshot), str(self.config), vault, str(self.transcript)],
                    cwd=working, env=dict(self.env, PROVIDER_NOTE="1"),
                    capture_output=True, text=True, timeout=20)
                self.assertEqual(
                    (result.returncode != 0, len(self.calls()) - calls,
                     set(self.case.rglob("*.md")) - before),
                    (True, 0, set()), (result.stdout, result.stderr))
                self.assertFalse(snapshot.exists(), "invalid vault leaked the raw snapshot")

    def test_partial_save_retry_saves_changed_delivered_evidence_before_acknowledging(self):
        self.transcript.write_text("")
        for i in range(14):
            self.message(f"big{i}", f"FACT-{i:02d} " + "note " * 1400)
        provider = dict(PROVIDER_NOTE="1", NOTE_DELIVERED_FACTS="1")
        self.run_hook(KEEPER_FAULT_INJECT="before_daily", **provider)
        self.assertEqual(self.seen_count(), 0)
        self.assertEqual({r["status"] for r in self.receipts()}, {"process_failed"})
        self.assertTrue(self.provider_rows()[0]["carry_forward"])
        self.assertGreater(self.provider_rows()[0]["retained_events"], 0)
        self.assertIn("FACT-00", self.provider_text())
        self.assertNotIn("FACT-13", self.provider_text())
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
        original = note.read_text()
        self.assertIn("- delivered: FACT-00", original)
        self.assertNotIn("- delivered: FACT-13", original)

        self.run_hook("--retry", KEEPER_FAULT_INJECT="before_append", **provider)
        self.assertFalse(self.provider_rows()[0]["carry_forward"])
        self.assertTrue(self.provider_rows()[0]["context_incomplete"])
        self.assertIn("FACT-13", self.provider_text())
        self.assertNotIn("FACT-00", self.provider_text())
        self.assertEqual(self.seen_count(), 0)
        self.assertEqual({r["status"] for r in self.receipts()}, {"process_failed"})
        self.assertEqual(note.read_text(), original)

        self.run_hook("--retry", **provider)
        saved = note.read_text()
        self.assertTrue(saved.startswith(original))
        self.assertEqual(saved.count("## Checkpoint "), 2)
        self.assertIn("- delivered: FACT-00", saved)
        self.assertIn("- delivered: FACT-13", saved)
        for row in self.provider_rows()[1:]:
            if row.get("text", "").startswith("FACT-"):
                self.assertIn("- delivered: " + row["text"].split()[0], saved)
        self.assertEqual(self.seen_count(), self.provider_rows()[0]["sent_events"])
        self.assertEqual({r["status"] for r in self.receipts()}, {"process_succeeded"})
        self.assertEqual({r["ack"] for r in self.receipts()}, {"acknowledged"})

    def test_partial_save_retry_with_only_instrumentation_does_not_duplicate_checkpoint(self):
        self.run_hook(PROVIDER_NOTE="1", KEEPER_FAULT_INJECT="before_daily")
        self.assertEqual(self.seen_count(), 0)
        self.assertEqual({r["status"] for r in self.receipts()}, {"process_failed"})
        first_rows = self.provider_rows()
        note, = (self.case / "vault/Inbox").glob("*-gate-fixture-*.md")
        original = note.read_text()
        with self.transcript.open("a") as stream:
            stream.write(json.dumps({"type": "progress", "data": "hook bookkeeping"}) + "\n")
        self.run_hook("--retry", PROVIDER_NOTE="1")
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.provider_rows()[1:], first_rows[1:])
        self.assertGreater(self.provider_rows()[0]["source_bytes"], first_rows[0]["source_bytes"])
        self.assertEqual(note.read_text(), original)
        self.assertEqual(note.read_text().count("## Checkpoint "), 1)
        self.assertEqual(self.seen_count(), self.provider_rows()[0]["sent_events"])
        self.assertEqual({r["status"] for r in self.receipts()}, {"process_succeeded"})
        daily, = (self.case / "vault/Daily").glob("*.md")
        self.assertEqual(daily.read_text().count(note.stem), 1)

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


class SummaryNoteTests(unittest.TestCase):
    helper = ROOT / "scripts/lib/summary-note.py"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="obsidian-summary-note-test-")
        self.addCleanup(self.temp.cleanup)
        self.case = Path(self.temp.name)
        for directory in ("vault/Daily", "vault/Inbox", "state"):
            (self.case / directory).mkdir(parents=True)
        self.env = dict(os.environ, XDG_STATE_HOME=str(self.case / "state"), HOME=str(self.case))
        self.pointers = self.case / "state/claude-obsidian/summary-notes"
        self.count = 0

    def command(self, date, rows, proposed, source="source.jsonl"):
        self.count += 1
        work = self.case / f"work{self.count}"
        work.mkdir()
        (work / "body.md").write_text("---\nsession_intent: execution\n---\n# Direct\nBody\n")
        (work / "usage.json").write_text(json.dumps({"started_at": f"{date}T00:00:00Z"}))
        lines = [{"kind": "extraction_metadata"}] + [{"text": row} for row in rows]
        (work / "input.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
        return ["python3", str(self.helper), str(self.case / "vault"), str(self.case / source), proposed,
                str(work / "body.md"), "Direct", date, "Daily", str(work / "usage.json"),
                str(work / "input.jsonl")]

    def run_note(self, *args, **kwargs):
        return subprocess.run(self.command(*args, **kwargs), capture_output=True, text=True,
                              env=self.env, check=False)

    def load_module(self):
        spec = importlib.util.spec_from_file_location("summary_note", self.helper)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_a_new_day_starts_a_separate_log(self):
        for day in ("2026-01-01", "2026-01-02"):
            self.assertEqual(self.run_note(day, ["one"], f"Inbox/{day}-direct.md").returncode, 0)
        self.assertEqual(len(list((self.case / "vault/Inbox").glob("*-direct-*.md"))), 2)
        self.assertEqual(len(list(self.pointers.glob("*.json"))), 2)

    def test_concurrent_checkpoints_serialize_on_the_pointer_lock(self):
        processes = [subprocess.Popen(self.command("2026-01-01", [row], "Inbox/2026-01-01-direct.md"),
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=self.env)
                     for row in ("alpha", "beta", "gamma", "delta")]
        for process in processes:
            _, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, stderr)
        note, = (self.case / "vault/Inbox").glob("*-direct-*.md")
        self.assertEqual(note.read_text().count("## Checkpoint "), 4)
        daily, = (self.case / "vault/Daily").glob("*.md")
        self.assertEqual(daily.read_text().count(note.stem), 1)

    def test_pointer_target_that_escapes_the_vault_is_refused(self):
        self.assertEqual(self.run_note("2026-01-01", ["one"], "Inbox/2026-01-01-direct.md").returncode, 0)
        pointer, = self.pointers.glob("*.json")
        for target in ("../escape.md", "/tmp/absolute.md", "Inbox/new\nline.md"):
            with self.subTest(target=target):
                pointer.write_text(json.dumps({"version": 1, "target": target, "ready": True}))
                result = self.run_note("2026-01-01", ["two"], "Inbox/2026-01-01-direct.md")
                self.assertEqual(result.returncode, 4)
                self.assertIn("invalid target", result.stderr)
        self.assertFalse((self.case / "escape.md").exists())

    def test_replaced_state_record_symlink_is_refused(self):
        self.assertEqual(self.run_note("2026-01-01", ["one"], "Inbox/direct.md").returncode, 0)
        pointer, = self.pointers.glob("*.json")
        outside = self.case / "outside.json"
        original = pointer.read_bytes()
        outside.write_bytes(original)
        pointer.unlink()
        pointer.symlink_to(outside)
        note, = (self.case / "vault/Inbox").glob("direct-*.md")
        before = note.read_bytes()

        result = self.run_note("2026-01-01", ["two"], "Inbox/direct.md")

        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("invalid state record", result.stderr)
        self.assertTrue(pointer.is_symlink())
        self.assertEqual(outside.read_bytes(), original)
        self.assertEqual(note.read_bytes(), before)

    def test_replaced_pointer_lock_symlink_is_not_followed(self):
        self.assertEqual(self.run_note("2026-01-01", ["one"], "Inbox/direct.md").returncode, 0)
        pointer, = self.pointers.glob("*.json")
        lock = Path(str(pointer) + ".lock")
        outside = self.case / "outside.lock"
        outside.write_text("lock sentinel")
        lock.unlink()
        lock.symlink_to(outside)
        note, = (self.case / "vault/Inbox").glob("direct-*.md")
        before = note.read_bytes(), pointer.read_bytes()

        result = self.run_note("2026-01-01", ["two"], "Inbox/direct.md")

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("checkpoint write failed (OSError)", result.stderr)
        self.assertTrue(lock.is_symlink())
        self.assertEqual(outside.read_text(), "lock sentinel")
        self.assertEqual((note.read_bytes(), pointer.read_bytes()), before)

    def test_ready_note_symlink_is_rejected_before_keeper_append(self):
        self.assertEqual(self.run_note("2026-01-01", ["one"], "Inbox/direct.md").returncode, 0)
        note, = (self.case / "vault/Inbox").glob("direct-*.md")
        outside = self.case / "outside.md"
        outside.write_text("note sentinel")
        note.unlink()
        note.symlink_to(outside)
        module = self.load_module()
        arguments = self.command("2026-01-01", ["two"], "Inbox/direct.md")[2:]

        # Keeper also refuses symlinks; isolate this guard so keeper cannot mask its removal.
        with mock.patch.dict(os.environ, self.env), mock.patch.object(
                module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as keeper:
            with self.assertRaisesRegex(ValueError, "missing canonical note"):
                module.save(*arguments)
            keeper.assert_not_called()
        self.assertTrue(note.is_symlink())
        self.assertEqual(outside.read_text(), "note sentinel")

    def test_stale_pointers_are_pruned_and_current_ones_kept(self):
        self.assertEqual(self.run_note("2026-01-01", ["one"], "Inbox/2026-01-01-direct.md").returncode, 0)
        stale = self.pointers / "stale-2025-01-01.json"
        recent = self.pointers / "recent-2025-12-31.json"
        for pointer in (stale, recent):
            pointer.write_text("{}")
            Path(str(pointer) + ".lock").write_text("")
        old = time.time() - 40 * 24 * 3600
        for path in (stale, Path(str(stale) + ".lock")):
            os.utime(path, (old, old))
        self.assertEqual(self.run_note("2026-01-01", ["two"], "Inbox/2026-01-01-direct.md").returncode, 0)
        self.assertFalse(stale.exists() or Path(str(stale) + ".lock").exists())
        self.assertTrue(recent.exists() and Path(str(recent) + ".lock").exists())
        self.assertEqual(len([p for p in self.pointers.glob("*.json") if "-2026-01-01" in p.name]), 1)

    def test_checkpoint_body_fence_syntax(self):
        body = self.load_module().checkpoint_body
        cases = {
            "tilde fence may carry backticks in its info": (
                "~~~ js `x`\n## in\n~~~\n## out\n", "~~~ js `x`\n## in\n~~~\n### out\n"),
            "a longer closing fence closes": (
                "```\n## in\n`````\n## out\n", "```\n## in\n`````\n### out\n"),
            "a shorter closing fence does not close": (
                "````\n## in\n```\n## still in\n````\n## out\n",
                "````\n## in\n```\n## still in\n````\n### out\n"),
            "CRLF fences": (
                "```\r\n## in\r\n```\r\n## out\r\n", "```\r\n## in\r\n```\r\n### out\r\n"),
            "an unclosed tilde fence is closed": ("~~~\n## in\n", "~~~\n## in\n\n~~~\n"),
            "a backtick opener with backticks in its info is not a fence": (
                "``` a`b\n## x\n", "``` a`b\n### x\n"),
        }
        for name, (text, expected) in cases.items():
            with self.subTest(name):
                self.assertEqual(body(text), expected)


if __name__ == "__main__":
    unittest.main()
