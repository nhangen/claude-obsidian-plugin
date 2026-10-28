import fcntl
import hashlib
import json
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
OWNER = ROOT / "scripts/lib/capture-owner.py"
OWNERS = (
    OWNER,
    ROOT / "packages/codex/skills/commit-capture/scripts/lib/capture-owner.py",
)


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="capture-ownership-")
        self.addCleanup(self.temporary.cleanup)
        self.case = Path(self.temporary.name).resolve()
        self.env = dict(
            os.environ,
            HOME=str(self.case / "home"),
            XDG_STATE_HOME=str(self.case / "state"),
            XDG_CONFIG_HOME=str(self.case / "config"),
            XDG_DATA_HOME=str(self.case / "data"),
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Fixture",
            GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Fixture",
            GIT_COMMITTER_EMAIL="fixture@example.invalid",
        )
        self.base = self.case / "state/claude-obsidian"
        self.state = self.base / "capture-ownership"
        self.vault = self.case / "vault"
        self.vault.mkdir()

    def run_owner(self, *args, payload=None, owner=OWNER):
        return subprocess.run(
            [sys.executable, str(owner), *args],
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
            *args,
        )

    def evidence(self, relative, value):
        path = self.base / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return path

    def checkpoint_history(self):
        return dict(
            version=1, seen=["a" * 64], git="b" * 64, head="c" * 40, last_attempt=100.5
        )

    def terminal_receipt(self):
        return dict(
            schema_version=1,
            source_session_hash="d" * 64,
            boundary="e" * 64,
            time=100.0,
            finished_at=101.0,
            status="process_succeeded",
            exit_code=0,
            retry_required=False,
            ack="acknowledged",
            attempt=1,
            stage="summarizer_process",
        )

    def state_snapshot(self):
        return {
            str(path.relative_to(self.case)): (
                stat.S_IMODE(path.lstat().st_mode),
                path.read_bytes() if path.is_file() else None,
            )
            for path in self.case.rglob("*")
        }

    def test_inspection_of_missing_root_is_read_only_in_both_packages(self):
        before = self.state_snapshot()
        for owner in OWNERS:
            with self.subTest(owner=owner):
                result = self.run_owner("inspect-legacy", owner=owner)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)
                self.assertEqual(value["status"], "legacy_evidence_clear")
                self.assertEqual(value["scope"], "legacy_evidence_only")
                self.assertTrue(value["ready"])
                self.assertEqual(value["ownership"]["generation"], 0)
                self.assertEqual(self.state_snapshot(), before)

    def test_old_checkpoint_is_history_with_indeterminate_delivery_not_new_pending(
        self,
    ):
        self.evidence(
            "session-capture/" + "d" * 64 + "/activity.json", self.checkpoint_history()
        )
        self.evidence(
            "session-capture/" + "d" * 64 + "/boundaries/" + "e" * 64 + ".json",
            self.terminal_receipt(),
        )
        before = self.state_snapshot()
        for owner in OWNERS:
            with self.subTest(owner=owner):
                result = self.run_owner("inspect-legacy", owner=owner)
                self.assertEqual(result.returncode, 1, result.stderr)
                value = json.loads(result.stdout)
                self.assertFalse(value["ready"])
                self.assertEqual(value["counts"].get("pending_activity", 0), 0)
                self.assertEqual(value["counts"]["legacy_checkpoint_history"], 1)
                history = next(
                    row
                    for row in value["evidence"]
                    if row["status"] == "legacy_checkpoint_history"
                )
                self.assertEqual(history["delivery"], "indeterminate")
                path = self.base / history["path"]
                self.assertEqual(
                    history["sha256"], hashlib.sha256(path.read_bytes()).hexdigest()
                )
                self.assertTrue(history["terminal_boundary_observed"])
                self.assertTrue(history["blocking"])
                self.assertEqual(self.state_snapshot(), before)
        result = self.handoff()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("legacy activity", result.stderr)

    def test_old_checkpoint_schema_is_exact_and_hashes_and_time_are_validated(self):
        valid = self.checkpoint_history()
        invalid = [
            dict(valid, version=True),
            dict(valid, version=2),
            dict(valid, last_attempt=True),
            dict(valid, last_attempt=float("inf")),
            dict(valid, last_attempt=float("nan")),
            dict(valid, last_attempt=-1),
            dict(valid, last_attempt=10**1000),
            dict(valid, seen="a" * 64),
            dict(valid, seen=["not-a-fingerprint"]),
            dict(valid, git="bad"),
            dict(valid, head="c" * 41),
            dict(valid, current=["a" * 64]),
            dict(valid, unexpected=True),
            {key: value for key, value in valid.items() if key != "head"},
            [valid],
        ]
        for owner in OWNERS:
            for value in invalid:
                with self.subTest(owner=owner, value=value):
                    self.evidence("session-capture/session/activity.json", value)
                    result = self.run_owner("inspect-legacy", owner=owner)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(
                        json.loads(result.stdout)["counts"]["invalid_activity"], 1
                    )
            self.evidence(
                "session-capture/session/activity.json",
                dict(valid, git=None, head=None),
            )
            result = self.run_owner("inspect-legacy", owner=owner)
            value = json.loads(result.stdout)
            self.assertEqual(value["counts"]["legacy_checkpoint_history"], 1)
            self.assertFalse(value["evidence"][0]["terminal_boundary_observed"])

    def test_pending_precedes_history_and_empty_pending_does_not_bless_unknown_schema(
        self,
    ):
        for owner in OWNERS:
            for value, expected in (
                (
                    dict(self.checkpoint_history(), pending=["f" * 64]),
                    "pending_activity",
                ),
                (
                    dict(self.checkpoint_history(), version=2, pending=[]),
                    "invalid_activity",
                ),
                (dict(self.checkpoint_history(), pending=""), "invalid_activity"),
                (dict(pending=[], unexpected=True), "invalid_activity"),
                (dict(seen=[], pending=[]), "invalid_activity"),
                (dict(pending=[]), "activity_clear"),
                (dict(pending=[], last_attempt=100.5), "activity_clear"),
                (dict(self.checkpoint_history(), pending=[]), "activity_clear"),
            ):
                with self.subTest(owner=owner, value=value):
                    self.evidence("session-capture/session/activity.json", value)
                    result = self.run_owner("inspect-legacy", owner=owner)
                    self.assertEqual(
                        result.returncode,
                        int(expected != "activity_clear"),
                        result.stderr,
                    )
                    self.assertEqual(json.loads(result.stdout)["counts"][expected], 1)
                    handoff = self.run_owner(
                        "handoff",
                        "--owner",
                        "disabled",
                        "--verification",
                        "legacy-writers-stopped-and-history-inspected",
                        owner=owner,
                    )
                    self.assertEqual(
                        handoff.returncode == 0,
                        expected == "activity_clear",
                        handoff.stderr,
                    )

    def test_malformed_evidence_is_reported_and_cannot_disappear_as_null(self):
        for relative in (
            "session-capture/session/activity.json",
            "session-capture/session/boundaries/event.json",
            "session-capture/session/launches/launch.json",
        ):
            self.evidence(relative, None)
        result = self.run_owner("inspect-legacy")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["counts"], dict(invalid_evidence=3))
        self.assertNotEqual(self.handoff().returncode, 0)

    def test_inspection_refuses_directory_symlinks_without_following_or_chmod(self):
        outside = self.case / "outside"
        outside.mkdir(mode=0o755)
        for relative in (
            "",
            "session-capture",
            "session-capture/session",
            "session-capture/session/boundaries",
            "capture-ownership/resolutions",
        ):
            with self.subTest(relative=relative):
                path = self.base / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to(outside, target_is_directory=True)
                before = self.state_snapshot()
                for owner in OWNERS:
                    result = self.run_owner("inspect-legacy", owner=owner)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(self.state_snapshot(), before)
                path.unlink()

    def test_inspection_limits_sessions_and_total_bytes_before_reporting_clear(self):
        sessions = self.base / "session-capture"
        sessions.mkdir(parents=True)
        for index in range(257):
            (sessions / str(index)).mkdir()
        result = self.run_owner("inspect-legacy")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("256 sessions", result.stderr)
        for session in sessions.iterdir():
            session.rmdir()
        boundaries = sessions / "one/boundaries"
        boundaries.mkdir(parents=True)
        for index in range(17):
            path = boundaries / (str(index) + ".json")
            path.write_text("{}" + " " * (1048576 - 2))
            path.chmod(0o600)
        result = self.run_owner("inspect-legacy")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("16 MiB", result.stderr)

    def test_resolution_can_bind_the_digest_inspected_before_acquiring_admission(self):
        path = self.evidence(
            "session-capture/session/activity.json", self.checkpoint_history()
        )
        report = self.run_owner("inspect-legacy")
        digest = json.loads(report.stdout)["evidence"][0]["sha256"]
        self.evidence(
            str(path.relative_to(self.base)),
            dict(self.checkpoint_history(), last_attempt=200.0),
        )
        changed = path.read_bytes()
        for owner in OWNERS:
            result = self.run_owner(
                "resolve-legacy",
                "--evidence",
                str(path.relative_to(self.base)),
                "--evidence-sha256",
                digest,
                "--verification",
                "authoritative-vault-and-history-inspected",
                "--reason",
                "Retain indeterminate history after inspection",
                owner=owner,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("changed since inspection", result.stderr)
            self.assertFalse((self.state / "resolutions").exists())
            self.assertEqual(path.read_bytes(), changed)
        current = self.run_owner("inspect-legacy")
        digest = json.loads(current.stdout)["evidence"][0]["sha256"]
        result = self.run_owner(
            "resolve-legacy",
            "--evidence",
            str(path.relative_to(self.base)),
            "--evidence-sha256",
            digest,
            "--verification",
            "authoritative-vault-and-history-inspected",
            "--reason",
            "Retain indeterminate history after renewed inspection",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout)["status"], "operator_resolved_not_mcp_receipt"
        )

    def test_terminal_receipt_corroboration_requires_same_session_boundary_and_time(
        self,
    ):
        self.evidence(
            "session-capture/" + "d" * 64 + "/activity.json", self.checkpoint_history()
        )
        for changes in (
            dict(source_session_hash="f" * 64),
            dict(boundary="f" * 64),
            dict(time=101.0),
            dict(finished_at=100.0),
            dict(ack="receipt_missing"),
        ):
            with self.subTest(changes=changes):
                self.evidence(
                    "session-capture/" + "d" * 64 + "/boundaries/" + "e" * 64 + ".json",
                    dict(self.terminal_receipt(), **changes),
                )
                result = self.run_owner("inspect-legacy")
                self.assertEqual(result.returncode, 1, result.stderr)
                history = next(
                    row
                    for row in json.loads(result.stdout)["evidence"]
                    if row["status"] == "legacy_checkpoint_history"
                )
                self.assertFalse(history["terminal_boundary_observed"])

    def test_ack_anomalies_and_unobserved_launches_remain_handoff_blockers(self):
        for ack in (None, "receipt_missing", "receipt_invalid", "ack_write_failed"):
            with self.subTest(ack=ack):
                receipt = self.terminal_receipt()
                if ack is None:
                    del receipt["ack"]
                else:
                    receipt["ack"] = ack
                self.evidence("session-capture/session/boundaries/event.json", receipt)
                result = self.handoff()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unresolved legacy session", result.stderr)
        self.evidence(
            "session-capture/session/boundaries/event.json", self.terminal_receipt()
        )
        path = self.evidence(
            "session-capture/session/launches/launch.json", dict(status="prepared")
        )
        before = self.state_snapshot()
        inspected = self.run_owner("inspect-legacy")
        self.assertEqual(json.loads(inspected.stdout)["counts"]["unobserved_launch"], 1)
        self.assertEqual(self.state_snapshot(), before)
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(json.loads(path.read_text())["status"], "prepared")

    def test_inspection_reports_all_blockers_without_closing_admission(self):
        for name in (
            "pre-commit-head/one",
            "pre-commit-head/two",
            "pre-commit-processing/three",
        ):
            self.evidence(name, dict(head_before="c" * 40))
        self.evidence(
            "session-capture/session/boundaries/failed.json",
            dict(status="process_failed", retry_required=True),
        )
        self.evidence(
            "session-capture/session/launches/unobserved.json", dict(status="started")
        )
        self.evidence(
            "session-capture/session/activity.json", self.checkpoint_history()
        )
        self.run_owner("status")
        lock = self.state / "admission.lock"
        lock.chmod(0o600)
        before = self.state_snapshot()
        result = self.run_owner("inspect-legacy")
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["blocking_count"], 6)
        self.assertEqual(
            report["counts"],
            dict(
                unresolved_commit=3,
                unresolved_receipt=1,
                unobserved_launch=1,
                legacy_checkpoint_history=1,
            ),
        )
        self.assertEqual(report["ownership"]["phase"], "stable")
        self.assertEqual(self.state_snapshot(), before)
        with lock.open() as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_owner("inspect-legacy")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(result.stdout)["counts"]["active_writer"], 1)
        self.assertEqual(self.state_snapshot(), before)

    def test_capture_can_enter_while_inspection_is_scanning(self):
        self.run_owner("status")
        for owner in OWNERS:
            with self.subTest(owner=owner), mock.patch.dict(os.environ, self.env):
                module = runpy.run_path(str(owner))
                inspect = module["inspect_legacy"]
                scan = module["legacy_inspection"]

                def scan_with_capture():
                    capture = self.run_owner(
                        "legacy", "--", sys.executable, "-c", "pass", owner=owner
                    )
                    self.assertEqual(capture.returncode, 0, capture.stderr)
                    return scan()

                with mock.patch.dict(
                    inspect.__globals__, legacy_inspection=scan_with_capture
                ):
                    self.assertTrue(inspect()["ready"])

    def test_history_requires_explicit_content_bound_resolution_in_both_packages(self):
        path = self.evidence(
            "session-capture/session/activity.json", self.checkpoint_history()
        )
        original = path.read_bytes()
        for owner in OWNERS:
            unresolved = self.run_owner("inspect-legacy", owner=owner)
            self.assertEqual(unresolved.returncode, 1, unresolved.stderr)
        resolved = self.run_owner(
            "resolve-legacy",
            "--evidence",
            str(path.relative_to(self.base)),
            "--verification",
            "authoritative-vault-and-history-inspected",
            "--reason",
            "Delivery remains indeterminate after authoritative inspection; retain history",
        )
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        self.assertEqual(
            json.loads(resolved.stdout)["status"], "operator_resolved_not_mcp_receipt"
        )
        for owner in OWNERS:
            report = self.run_owner("inspect-legacy", owner=owner)
            self.assertEqual(report.returncode, 0, report.stderr)
            self.assertEqual(
                json.loads(report.stdout)["counts"]["operator_resolved"], 1
            )
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(self.handoff().returncode, 0)
        self.evidence(
            str(path.relative_to(self.base)),
            dict(self.checkpoint_history(), last_attempt=200.0),
        )
        self.assertEqual(self.run_owner("inspect-legacy").returncode, 1)
        self.assertNotEqual(self.handoff("legacy").returncode, 0)

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
            self.terminal_receipt(),
        )
        for value in (dict(seen=["old"]), dict(seen=["old"], pending=["unsent"])):
            with self.subTest(value=value):
                self.evidence("session-capture/session/activity.json", value)
                result = self.handoff()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("legacy activity", result.stderr)
        self.evidence(
            "session-capture/session/activity.json",
            dict(self.checkpoint_history(), pending=[]),
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
        command = (
            "legacy",
            "--",
            "bash",
            str(ROOT / "scripts/keeper"),
            "append",
            "--vault",
            str(self.vault),
            "--target",
            "Notes/commit.md",
            "--section",
            "## 12:00 " + commit,
            "--skip-if-hash",
            commit,
        )
        self.env["KEEPER_FAULT_INJECT"] = "before_append"
        failed = self.run_owner(*command, payload="Private inherited-lease context")
        self.assertNotEqual(failed.returncode, 0)
        (pending,) = (self.state / "pending-commits").glob("*.json")
        original = pending.read_bytes()
        self.assertNotIn(b"Private inherited-lease context", original)
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(pending.read_bytes(), original)
        self.assertEqual(self.run_owner("resume").returncode, 0)
        del self.env["KEEPER_FAULT_INJECT"]
        succeeded = self.run_owner(*command, payload="Private inherited-lease context")
        self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
        self.assertFalse(pending.exists())
        (archived,) = (self.state / "acknowledged-commits").glob("*.json")
        self.assertEqual(archived.read_bytes(), original)
        self.assertIn(commit, (self.vault / "Notes/commit.md").read_text())
        self.assertEqual(self.handoff().returncode, 0)

    def test_installed_git_hook_failure_and_readmission_remain_pending_until_retry(
        self,
    ):
        repo = self.case / "git-hook-repo"
        config = self.case / "config.md"
        config.write_text(f"---\nvault_path: {self.vault}\n---\n")
        self.env.update(
            OBSIDIAN_LOCAL_MD=str(config), KEEPER_FAULT_INJECT="before_append"
        )

        def run(*command):
            return subprocess.run(
                command,
                env=self.env,
                capture_output=True,
                text=True,
                timeout=15,
                cwd=self.case,
            )

        self.assertEqual(run("git", "init", "-q", str(repo)).returncode, 0)
        installed = run(
            "bash", str(ROOT / "scripts/install-git-hook.sh"), "install", str(repo)
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        committed = run(
            "git",
            "-C",
            str(repo),
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--allow-empty",
            "-qm",
            "Fixture capture failure",
        )
        self.assertEqual(committed.returncode, 0, committed.stderr)
        self.assertIn("keeper append failed", committed.stderr)
        commit = run("git", "-C", str(repo), "rev-parse", "HEAD").stdout.strip()
        (pending,) = (self.state / "pending-commits").glob("*.json")
        original = pending.read_bytes()
        record = json.loads(original)
        self.assertEqual(record["hash"], commit)
        self.assertEqual(record["vault"], str(self.vault))
        self.assertEqual(set(record), {"hash", "vault", "target"})
        hook = repo / ".git/hooks/post-commit"

        def replay():
            return run(
                "git",
                "-C",
                str(repo),
                "-c",
                "alias.capture=!bash " + str(hook),
                "capture",
            )

        self.assertIn("keeper append failed", replay().stderr)
        self.assertEqual(pending.read_bytes(), original)
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(self.run_owner("resume").returncode, 0)
        resolved = self.run_owner(
            "resolve-legacy",
            "--evidence",
            str(pending.relative_to(self.base)),
            "--verification",
            "authoritative-vault-and-history-inspected",
            "--reason",
            "Fixture operator inspected the failed capture",
        )
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        (resolution,) = (self.state / "resolutions").glob("*.json")
        history = resolution.read_bytes()
        self.assertIn("keeper append failed", replay().stderr)
        readmitted = pending.read_bytes()
        self.assertNotEqual(readmitted, original)
        self.assertEqual(resolution.read_bytes(), history)
        self.assertIn("keeper append failed", replay().stderr)
        self.assertEqual(pending.read_bytes(), readmitted)
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(self.run_owner("resume").returncode, 0)
        del self.env["KEEPER_FAULT_INJECT"]
        succeeded = replay()
        self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
        self.assertNotIn("keeper append failed", succeeded.stderr)
        self.assertFalse(pending.exists())
        self.assertIn(commit, (self.vault / record["target"]).read_text())
        self.assertEqual(resolution.read_bytes(), history)
        self.assertEqual(self.handoff().returncode, 0)

    def test_full_hash_append_rejects_duplicate_identity_options_before_write(self):
        for option, value in (
            ("--vault", str(self.case / "other")),
            ("--target", "Notes/other.md"),
            ("--skip-if-hash", "c" * 40),
        ):
            with self.subTest(option=option):
                result = self.run_owner(
                    "legacy",
                    "--",
                    "bash",
                    str(ROOT / "scripts/keeper"),
                    "append",
                    "--vault",
                    str(self.vault),
                    "--target",
                    "Notes/commit.md",
                    "--section",
                    "## 12:00 " + "b" * 40,
                    "--skip-if-hash",
                    "b" * 40,
                    option,
                    value,
                    payload="Private context",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("duplicate", result.stderr)
                self.assertFalse((self.vault / "Notes/commit.md").exists())
                self.assertFalse((self.vault / "Notes/other.md").exists())

    def test_full_hash_append_registration_failure_prevents_keeper_write(self):
        self.run_owner("status")
        self.evidence("capture-ownership/pending-commits", {})
        result = self.run_owner(
            "legacy",
            "--",
            "bash",
            str(ROOT / "scripts/keeper"),
            "append",
            "--vault",
            str(self.vault),
            "--target",
            "Notes/commit.md",
            "--section",
            "## 12:00 " + "a" * 40,
            "--skip-if-hash",
            "a" * 40,
            payload="Must not be written",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.vault / "Notes/commit.md").exists())

    def test_full_hash_append_without_verified_heading_stays_pending(self):
        result = self.run_owner(
            "legacy",
            "--",
            "bash",
            str(ROOT / "scripts/keeper"),
            "append",
            "--vault",
            str(self.vault),
            "--target",
            "Notes/commit.md",
            "--section",
            "## Heading without the commit",
            "--skip-if-hash",
            "a" * 40,
            payload="Written but not acknowledged",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("heading readback failed", result.stderr)
        self.assertIn(
            "Written but not acknowledged", (self.vault / "Notes/commit.md").read_text()
        )
        self.assertEqual(len(list((self.state / "pending-commits").glob("*.json"))), 1)
        self.assertNotEqual(self.handoff().returncode, 0)

    def test_uppercase_full_hash_registers_and_acknowledges_but_short_hash_stays_manual(
        self,
    ):
        command = (
            "legacy",
            "--",
            "bash",
            str(ROOT / "scripts/keeper"),
            "append",
            "--vault",
            str(self.vault),
            "--target",
            "Notes/commit.md",
            "--section",
            "## 12:00 " + "AB" * 20,
            "--skip-if-hash",
            "AB" * 20,
        )
        self.env["KEEPER_FAULT_INJECT"] = "before_append"
        self.assertNotEqual(
            self.run_owner(*command, payload="Private context").returncode, 0
        )
        (pending,) = (self.state / "pending-commits").glob("*.json")
        self.assertEqual(json.loads(pending.read_text())["hash"], "ab" * 20)
        del self.env["KEEPER_FAULT_INJECT"]
        succeeded = self.run_owner(*command, payload="Private context")
        self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
        self.assertFalse(pending.exists())
        short_command = list(command)
        short_command[short_command.index("--target") + 1] = "Notes/short.md"
        short_command[short_command.index("--section") + 1] = "## 12:00 deadbee"
        short_command[-1] = "deadbee"
        short = self.run_owner(*short_command, payload="Manual context")
        self.assertEqual(short.returncode, 0, short.stderr)
        self.assertFalse(list((self.state / "pending-commits").glob("*.json")))

    def test_full_hash_date_append_retains_and_acknowledges_daily_target(self):
        commit = "c" * 40
        body = self.case / "date-body.md"
        body.write_text("Date-shaped capture\n")
        command = [
            "bash",
            str(ROOT / "scripts/keeper"),
            "append",
            "--vault",
            str(self.vault),
            "--date",
            "2026-10-27",
            "--section",
            "## 12:00 " + commit,
            "--body-file",
            str(body),
            "--skip-if-hash",
            commit,
        ]
        failed = subprocess.run(
            command,
            env=dict(self.env, KEEPER_FAULT_INJECT="before_append"),
            capture_output=True,
            timeout=10,
        )
        self.assertNotEqual(failed.returncode, 0)
        pending = list((self.state / "pending-commits").glob("*.json"))
        self.assertEqual(len(pending), 1)
        self.assertEqual(
            json.loads(pending[0].read_text())["target"], "Daily/2026-10-27.md"
        )
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(self.run_owner("resume").returncode, 0)
        success = subprocess.run(command, env=self.env, capture_output=True, timeout=10)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertFalse(pending[0].exists())
        self.assertIn(commit, (self.vault / "Daily/2026-10-27.md").read_text())

    def test_configured_vault_full_hash_append_retains_resolved_identity(self):
        commit = "d" * 40
        config = self.case / "obsidian.local.md"
        config.write_text("---\nvault_path: " + str(self.vault) + "\n---\n")
        self.env["OBSIDIAN_LOCAL_MD"] = str(config)
        body = self.case / "configured-body.md"
        body.write_text("Configured capture\n")
        command = [
            "bash",
            str(ROOT / "scripts/keeper"),
            "append",
            "--target",
            "Notes/configured.md",
            "--section",
            "## 12:00 " + commit,
            "--body-file",
            str(body),
            "--skip-if-hash",
            commit,
        ]
        failed = subprocess.run(
            command,
            env=dict(self.env, KEEPER_FAULT_INJECT="before_append"),
            capture_output=True,
            timeout=10,
        )
        self.assertNotEqual(failed.returncode, 0)
        pending = list((self.state / "pending-commits").glob("*.json"))
        self.assertEqual(len(pending), 1)
        self.assertEqual(json.loads(pending[0].read_text())["vault"], str(self.vault))
        self.assertNotEqual(self.handoff().returncode, 0)
        self.assertEqual(self.run_owner("resume").returncode, 0)
        succeeded = subprocess.run(
            command, env=self.env, capture_output=True, timeout=10
        )
        self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
        self.assertFalse(pending[0].exists())

    def test_fenced_examples_and_unclosed_fences_do_not_acknowledge_capture(self):
        for existing in (False, True):
            with self.subTest(existing=existing):
                commit = ("e" if existing else "f") * 40
                target = "Notes/fenced-" + str(existing) + ".md"
                note = self.vault / target
                note.parent.mkdir(exist_ok=True)
                body = self.case / ("fenced-body-" + str(existing))
                if existing:
                    note.write_text("```markdown\nAn unclosed prior fence\n")
                    body.write_text("Real context\n")
                    section = "## 12:00 " + commit
                else:
                    body.write_text("```markdown\n## 12:00 " + commit + "\n```\n")
                    section = "## Examples only"
                result = subprocess.run(
                    [
                        "bash",
                        str(ROOT / "scripts/keeper"),
                        "append",
                        "--vault",
                        str(self.vault),
                        "--target",
                        target,
                        "--section",
                        section,
                        "--body-file",
                        str(body),
                        "--skip-if-hash",
                        commit,
                    ],
                    env=self.env,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("heading readback failed", result.stderr)
                pending = [
                    p
                    for p in (self.state / "pending-commits").glob("*.json")
                    if json.loads(p.read_text())["hash"] == commit
                ]
                self.assertEqual(len(pending), 1)
                self.assertNotEqual(self.handoff().returncode, 0)
                self.assertEqual(self.run_owner("resume").returncode, 0)

    def test_heading_verifier_reuses_production_parser_without_writes(self):
        commit = "a" * 40
        note = self.vault / "verified.md"
        note.write_text("## 12:00 " + commit + "\nBody\n")
        before = note.read_bytes()
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/keeper-core"),
                "has-commit-heading",
                str(note),
                commit,
            ],
            env=self.env,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(note.read_bytes(), before)
        missing = self.vault / "absent.md"
        absent = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/keeper-core"),
                "has-commit-heading",
                str(missing),
                commit,
            ],
            env=self.env,
            capture_output=True,
            timeout=10,
        )
        self.assertNotEqual(absent.returncode, 0)
        self.assertFalse(missing.exists())

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
