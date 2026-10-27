import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
OWNER = ROOT / "scripts/lib/capture-owner.py"


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="capture-ownership-")
        self.addCleanup(self.temporary.cleanup)
        self.case = Path(self.temporary.name).resolve()
        self.env = dict(
            os.environ,
            HOME=str(self.case / "home"),
            XDG_STATE_HOME=str(self.case / "state"),
        )
        self.base = self.case / "state/claude-obsidian"
        self.state = self.base / "capture-ownership"
        self.vault = self.case / "vault"
        self.vault.mkdir()

    def run_owner(self, *args, payload=None):
        return subprocess.run(
            [sys.executable, str(OWNER), *args],
            input=payload,
            text=True,
            env=self.env,
            capture_output=True,
            timeout=10,
        )

    def handoff(self, owner="disabled", *args):
        return self.run_owner(
            "handoff",
            "--owner",
            owner,
            "--verification",
            "legacy-writers-stopped-and-history-inspected",
            *args
        )

    def evidence(self, relative, value):
        path = self.base / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return path

    def test_default_is_legacy_and_disabled_gates_real_keeper(self):
        result = self.run_owner("status")
        self.assertEqual(json.loads(result.stdout)["owner"], "legacy")
        self.assertEqual(self.handoff().returncode, 0)
        body = self.case / "body"
        body.write_text("must not be written")
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/keeper"),
                "insert",
                "--vault",
                str(self.vault),
                "--target",
                "Inbox/refused.md",
                "--body-file",
                str(body),
            ],
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no local fallback", result.stderr)
        self.assertFalse((self.vault / "Inbox/refused.md").exists())

    def test_handoff_requires_old_client_attestation(self):
        result = self.run_owner("handoff", "--owner", "disabled")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / "owner.json").exists())

    def test_disabled_owner_denies_mcp_writes_without_blocking_ordinary_shell(self):
        self.assertEqual(self.handoff().returncode, 0)
        for tool in (
            "mcp__obsidian-write__obsidian_keeper_save",
            "mcp__obsidian-write__obsidian_daily_append",
        ):
            denied = self.run_owner(
                "route",
                "--event",
                "PreToolUse",
                payload=json.dumps(dict(tool_name=tool, tool_input={})),
            )
            self.assertEqual(
                json.loads(denied.stdout)["hookSpecificOutput"]["permissionDecision"],
                "deny",
            )
        shell = self.run_owner(
            "route",
            "--event",
            "PreToolUse",
            payload='{"tool_name":"Bash","tool_input":{"command":"git status"}}',
        )
        self.assertNotIn("hookSpecificOutput", json.loads(shell.stdout))

    def test_client_ownership_does_not_disable_authoritative_server_primitive(self):
        self.assertEqual(self.handoff().returncode, 0)
        body = self.case / "body"
        body.write_text("Authoritative server write")
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "packages/mcp-server/helpers/keeper"),
                "insert",
                "--vault",
                str(self.vault),
                "--target",
                "Inbox/server.md",
                "--body-file",
                str(body),
            ],
            env=self.env,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "Authoritative server write", (self.vault / "Inbox/server.md").read_text()
        )

    def test_packaged_legacy_codex_writer_honors_same_owner(self):
        self.assertEqual(self.handoff().returncode, 0)
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "packages/codex/skills/commit-capture/scripts/keeper"),
                "append",
                "--vault",
                str(self.vault),
                "--target",
                "Notes/refused.md",
            ],
            input=b"Never written",
            env=self.env,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.vault / "Notes/refused.md").exists())

    def test_pending_evidence_closes_admission_without_erasing_evidence(self):
        path = self.evidence("pre-commit-head/interrupted", {"sha": "unresolved"})
        original = path.read_bytes()
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(path.read_bytes(), original)
        status = json.loads(self.run_owner("status").stdout)
        self.assertEqual(status["phase"], "draining")
        refused = self.run_owner(
            "legacy", "--", sys.executable, "-c", "raise SystemExit(0)"
        )
        self.assertNotEqual(refused.returncode, 0)

    def test_operator_resolution_preserves_evidence_and_is_content_bound(self):
        path = self.evidence("pre-commit-head/interrupted", {"sha": "unresolved"})
        self.assertNotEqual(self.handoff().returncode, 0)
        result = self.run_owner(
            "resolve-legacy",
            "--evidence",
            "pre-commit-head/interrupted",
            "--verification",
            "authoritative-vault-and-history-inspected",
            "--reason",
            "Command was denied; history unchanged",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout)["status"], "operator_resolved_not_mcp_receipt"
        )
        self.assertTrue(path.exists())
        self.assertEqual(self.handoff().returncode, 0)
        path.write_text('{"sha":"changed"}')
        self.assertNotEqual(self.handoff("legacy").returncode, 0)

    def test_failed_session_receipt_blocks_even_without_running_process(self):
        self.evidence(
            "session-capture/session/boundaries/event.json",
            dict(status="process_failed", retry_required=True),
        )
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertIn("unresolved legacy session", self.handoff().stderr)

    def test_successful_process_does_not_hide_retained_or_unknown_activity(self):
        self.evidence(
            "session-capture/session/boundaries/event.json",
            dict(status="process_succeeded", retry_required=False),
        )
        for value in (dict(seen=["old"]), dict(seen=["old"], pending=["unsent"])):
            with self.subTest(value=value):
                self.evidence("session-capture/session/activity.json", value)
                result = self.handoff()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("legacy activity", result.stderr)
        self.evidence(
            "session-capture/session/activity.json", dict(seen=["old"], pending=[])
        )
        self.assertEqual(self.handoff().returncode, 0)

    def test_cancelled_handoff_reopens_same_owner_for_deliberate_recovery(self):
        path = self.evidence(
            "session-capture/session/boundaries/event.json",
            dict(status="process_failed", retry_required=True),
        )
        self.assertNotEqual(self.handoff().returncode, 0)
        result = self.run_owner("resume")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual((value["owner"], value["phase"]), ("legacy", "stable"))
        self.assertTrue(path.exists())
        retried = self.run_owner(
            "legacy", "--", sys.executable, "-c", "print('recovery command admitted')"
        )
        self.assertEqual(retried.returncode, 0)
        self.assertNotEqual(self.handoff().returncode, 0)

    def test_active_old_worker_lock_blocks_transition(self):
        path = self.evidence("session-capture/session/activity.lock", {})
        with path.open("r+") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(self.handoff().returncode, 0)

    def test_admission_precedes_spawn_and_survives_supervisor_death(self):
        ready, release = self.case / "ready", self.case / "release"
        worker = self.case / "worker.py"
        worker.write_text(
            "import os,pathlib,time\n"
            "pathlib.Path(os.environ['READY']).touch()\n"
            "while not pathlib.Path(os.environ['RELEASE']).exists(): time.sleep(.01)\n"
        )
        env = dict(self.env, READY=str(ready), RELEASE=str(release))
        process = subprocess.Popen(
            [sys.executable, str(OWNER), "legacy", "--", sys.executable, str(worker)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 5
            while not ready.exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            self.assertNotEqual(self.handoff().returncode, 0)
            self.assertFalse((self.state / "owner.json").exists())
            process.kill()
            self.assertNotEqual(self.handoff().returncode, 0)
            release.touch()
            process.communicate(timeout=5)
            deadline = time.monotonic() + 5
            while self.handoff().returncode:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
        finally:
            release.touch()
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    def test_disabled_stops_all_hook_entrypoints_without_snapshots(self):
        self.assertEqual(self.handoff().returncode, 0)
        for script in ("session-save.sh", "commit-capture-pre.sh", "commit-capture.sh"):
            result = subprocess.run(
                ["bash", str(ROOT / "scripts" / script)],
                input='{"tool_input":{"command":"git commit -m test"}}',
                capture_output=True,
                text=True,
                env=self.env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("disabled", result.stdout)
        self.assertFalse((self.base / "pre-commit-head").exists())

    def test_incomplete_public_profile_is_not_accepted(self):
        profile = self.case / "profile"
        profile.mkdir(mode=0o700)
        config = profile / "capture-profile.json"
        config.write_text(
            json.dumps(
                dict(
                    host="codex",
                    project=str(self.case),
                    active=True,
                    bundle=str(self.case),
                )
            )
        )
        config.chmod(0o600)
        result = self.handoff(
            "mcp", "--profile", str(profile), "--project", str(self.case)
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("claude-plugin profile", result.stderr)
        self.assertEqual(
            json.loads(self.run_owner("status").stdout)["phase"], "draining"
        )

    def test_pending_commit_settles_only_after_real_keeper_and_heading_readback(self):
        commit = "a" * 40
        target = "Projects/Development/example/repo/2026-10-27.md"
        recorded = self.run_owner(
            "record-commit",
            "--commit",
            commit,
            "--vault",
            str(self.vault),
            "--target",
            target,
        )
        self.assertEqual(recorded.returncode, 0, recorded.stderr)
        (pending,) = (self.state / "pending-commits").glob("*.json")
        body = self.case / "body"
        body.write_text("Context for the observed commit")
        command = [
            "bash",
            str(ROOT / "scripts/keeper"),
            "append",
            "--vault",
            str(self.vault),
            "--target",
            target,
            "--body-file",
            str(body),
            "--section",
            "## 12:00 " + commit,
            "--skip-if-hash",
            commit,
        ]
        failed = subprocess.run(
            command,
            env=dict(self.env, KEEPER_FAULT_INJECT="before_append"),
            capture_output=True,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue(pending.exists())
        succeeded = subprocess.run(command, env=self.env, capture_output=True)
        self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
        self.assertFalse(pending.exists())
        self.assertEqual(
            len(list((self.state / "acknowledged-commits").glob("*.json"))), 1
        )
        self.assertIn(commit, (self.vault / target).read_text())

    def test_nested_keeper_with_inherited_lease_keeps_pending_evidence(self):
        commit = "b" * 40
        result = self.run_owner(
            "record-commit",
            "--commit",
            commit,
            "--vault",
            str(self.vault),
            "--target",
            "Notes/commit.md",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(len(list((self.state / "pending-commits").glob("*.json"))), 1)

    def test_stop_error_has_only_one_blocking_continuation(self):
        self.run_owner("status")
        self.evidence(
            "capture-ownership/owner.json",
            dict(schema=1, owner="legacy", phase="draining", generation=1, profiles={}),
        )
        first = self.run_owner(
            "route", "--event", "Stop", payload='{"stop_hook_active":false}'
        )
        again = self.run_owner(
            "route", "--event", "Stop", payload='{"stop_hook_active":true}'
        )
        self.assertEqual(json.loads(first.stdout)["decision"], "block")
        self.assertNotIn("decision", json.loads(again.stdout))
        self.assertIn("systemMessage", json.loads(again.stdout))

    def test_unmapped_mcp_project_does_not_fall_back(self):
        subprocess.run(["git", "init", "-q", str(self.case)], check=True)
        self.run_owner("status")
        self.evidence(
            "capture-ownership/owner.json",
            dict(schema=1, owner="mcp", phase="stable", generation=1, profiles={}),
        )
        result = self.run_owner(
            "route",
            "--event",
            "Stop",
            "--script",
            str(ROOT / "scripts/session-save.sh"),
            payload=json.dumps(dict(cwd=str(self.case))),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["decision"], "block")
        self.assertIn("no legacy fallback", result.stderr)
        self.assertFalse((self.base / "session-capture").exists())

    def test_empty_state_home_and_symlink_record_refuse(self):
        self.env["XDG_STATE_HOME"] = ""
        self.assertNotEqual(self.run_owner("status").returncode, 0)
        self.env["XDG_STATE_HOME"] = str(self.case / "state")
        self.run_owner("status")
        secret = self.case / "secret"
        secret.write_text("SENSITIVE VALUE")
        (self.state / "owner.json").symlink_to(secret)
        result = self.handoff()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SENSITIVE VALUE", result.stderr)

    def mock_runtime(self, program):
        subprocess.run(["git", "init", "-q", str(self.case)], check=True)
        bundle = self.case / "mock-bundle"
        (bundle / "bin").mkdir(parents=True)
        (bundle / "bin/obsidian-mcp-native").write_text(program)
        profile = self.case / "mock-profile"
        profile.mkdir(mode=0o700)
        path = profile / "capture-profile.json"
        path.write_text(
            json.dumps(
                dict(
                    host="claude-plugin",
                    project=str(self.case),
                    active=True,
                    bundle=str(bundle),
                )
            )
        )
        path.chmod(0o600)
        self.run_owner("status")
        self.evidence(
            "capture-ownership/owner.json",
            dict(
                schema=1,
                owner="mcp",
                phase="stable",
                generation=1,
                profiles={str(self.case): str(profile)},
            ),
        )

    def test_failed_public_runtime_becomes_explicit_event_refusal(self):
        self.mock_runtime(
            "import sys\nprint('SENSITIVE STDERR', file=sys.stderr)\nraise SystemExit(64)\n"
        )
        for event in (
            "UserPromptSubmit",
            "PreToolUse",
            "Stop",
            "PostToolUse",
            "PostToolUseFailure",
        ):
            with self.subTest(event=event):
                result = self.run_owner(
                    "route",
                    "--event",
                    event,
                    payload=json.dumps(dict(cwd=str(self.case))),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                output = json.loads(result.stdout)
                if event in ("UserPromptSubmit", "Stop"):
                    self.assertEqual(output["decision"], "block")
                elif event == "PreToolUse":
                    self.assertEqual(
                        output["hookSpecificOutput"]["permissionDecision"], "deny"
                    )
                else:
                    self.assertIn(
                        "failed", output["hookSpecificOutput"]["additionalContext"]
                    )
                self.assertNotIn("SENSITIVE STDERR", result.stdout + result.stderr)
        again = self.run_owner(
            "route",
            "--event",
            "Stop",
            payload=json.dumps(dict(cwd=str(self.case), stop_hook_active=True)),
        )
        self.assertIn("systemMessage", json.loads(again.stdout))
        self.assertNotIn("decision", json.loads(again.stdout))
        self.assertFalse((self.base / "session-capture").exists())

    def test_malformed_public_hook_output_cannot_allow_tool(self):
        self.mock_runtime("print('[]')\n")
        for response in (
            "[]",
            "{not json",
            '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}',
            '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":"not an object"}}',
        ):
            (self.case / "mock-bundle/bin/obsidian-mcp-native").write_text(
                "print(" + repr(response) + ")\n"
            )
            result = self.run_owner(
                "route",
                "--event",
                "PreToolUse",
                payload=json.dumps(dict(cwd=str(self.case))),
            )
            self.assertEqual(
                json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"],
                "deny",
            )


if __name__ == "__main__":
    unittest.main()
