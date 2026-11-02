#!/usr/bin/env python3
"""Installed-package admission against the packed public engine, without providers."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PUBLIC_HEAD = "f511884950777179de8e5bc47a2a5dd2bca52b7c"
VERIFICATION = "legacy-writers-stopped-and-history-inspected"
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"


class ActivationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = os.environ.get("OBSIDIAN_PUBLIC_CLIENT_SOURCE")
        if not source:
            raise RuntimeError(
                "OBSIDIAN_PUBLIC_CLIENT_SOURCE is required; no skip or fetch"
            )
        cls.source = Path(source).resolve(strict=True)
        head = subprocess.check_output(
            ["git", "-C", str(cls.source), "rev-parse", "HEAD"], text=True
        ).strip()
        if head != PUBLIC_HEAD:
            raise RuntimeError("public source must be pinned to " + PUBLIC_HEAD)
        cls.temporary = tempfile.TemporaryDirectory(prefix="codex-activation-")
        cls.root = Path(cls.temporary.name).resolve()
        cls.bundle = cls.root / "public-client"
        subprocess.run(
            [
                sys.executable,
                "-B",
                str(cls.source / "scripts/pack-obsidian-mcp-client.py"),
                "--output",
                str(cls.bundle),
            ],
            check=True,
            capture_output=True,
        )
        cls.digest = hashlib.sha256(
            (cls.bundle / "release.json").read_bytes()
        ).hexdigest()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.installed = self.directory / "installed package"
        shutil.copytree(ROOT / "packages/codex", self.installed)
        self.helper = self.installed / "scripts/capture.py"
        self.home = self.directory / "normal-codex"
        self.home.mkdir()
        (self.home / "config.toml").write_text("# untouched\n")
        self.profile = self.directory / "attached"
        runtime_home = self.directory / "home"
        runtime_home.mkdir()
        self.env = dict(
            os.environ,
            HOME=str(runtime_home),
            CODEX_HOME=str(self.home),
            PYTHONDONTWRITEBYTECODE="1",
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
        )
        for kind in ("STATE", "CONFIG", "DATA", "CACHE"):
            self.env["XDG_" + kind + "_HOME"] = str(runtime_home / kind.lower())
        self.state = Path(self.env["XDG_STATE_HOME"]) / "claude-obsidian"
        self.project = self.directory / "project"
        self.project.mkdir()
        subprocess.run(
            ["git", "-C", str(self.project), "init", "-q"], check=True, env=self.env
        )

    def cli(self, *args, payload=None, helper=None):
        return subprocess.run(
            [sys.executable, "-B", str(helper or self.helper), *args],
            input=json.dumps(payload) if payload is not None else "",
            env=self.env,
            capture_output=True,
            text=True,
            timeout=40,
        )

    def native(self, *args):
        result = self.cli(*args, helper=self.bundle / "bin/obsidian-mcp-native")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def activation(self, apply=True, **extra):
        options = dict(
            bundle=str(self.bundle),
            release_sha256=self.digest,
            profile=str(self.profile),
            codex_home=str(self.home),
        )
        options.update(extra)
        arguments = ["codex-activate"]
        for key, value in options.items():
            arguments.extend(("--" + key.replace("_", "-"), value))
        if not self.profile.exists():
            arguments.append("--create-profile")
        if apply:
            arguments.extend(("--apply", "--verification", VERIFICATION))
        return self.cli(*arguments)

    def activate(self):
        result = self.activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def record_path(self):
        return (
            self.state
            / "capture-ownership/codex"
            / (hashlib.sha256(str(self.home).encode()).hexdigest() + ".json")
        )

    def event(self, name, delivery="plugin", **extra):
        payload = dict(
            hook_event_name=name,
            session_id="native-session",
            turn_id="native-turn",
            cwd=str(self.project),
        )
        payload.update(extra)
        result = self.cli(
            "codex-route", "--delivery", delivery, "--event", name, payload=payload
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout or "{}")

    def states(self):
        return list((self.profile / "workspaces").glob("*/capture-state/*.json"))

    def snapshot(self, directory=None):
        return {
            str(p.relative_to(directory or self.directory)): p.read_bytes()
            for p in (directory or self.directory).rglob("*")
            if p.is_file() and (directory is None or p.suffix != ".lock")
        }

    def global_owner(self, **extra):
        path = self.state / "capture-ownership/owner.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.parent.chmod(0o700)
        value = dict(
            schema=1, owner="legacy", phase="stable", generation=7, profiles={}
        )
        value.update(extra)
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return path

    def test_installed_dormancy_and_preview_write_nothing(self):
        before = self.snapshot()
        self.assertEqual(self.event("UserPromptSubmit", prompt="work"), {})
        result = self.cli("codex-status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "dormant")
        result = self.activation(apply=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.state.exists())

    def test_real_native_ids_duplicates_receipts_and_workspace_modes(self):
        self.activate()
        config = (self.home / "config.toml").read_bytes()
        output = self.event("UserPromptSubmit", prompt="Record meaningful work")
        self.assertIn("native-turn", json.dumps(output))
        paths = self.states()
        self.assertEqual(len(paths), 1)
        path = paths[0]
        original = path.read_bytes()
        value = json.loads(original)
        self.assertEqual(value["turn"], "native-turn")
        self.assertNotIn("claude_transcript", value)
        self.event("UserPromptSubmit", prompt="Record meaningful work")
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(
            self.event("UserPromptSubmit", delivery="managed", prompt="ignored"), {}
        )
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse(
            self.native("drain-status", "--home", str(self.profile))["quiescent"]
        )
        plan = value["session_save"]
        tool = dict(
            tool_name="mcp__obsidian_write__obsidian_keeper_save",
            tool_use_id="save-native",
            tool_input=dict(
                title=plan["title"],
                folder_hint=plan["folder"],
                body="Fixture facts",
                resolved=True,
                session_link_date=plan["date"],
                idempotency_key=plan["idempotency_key"],
            ),
        )
        self.assertEqual(self.event("PreToolUse", **tool), {})
        receipt = dict(
            status="committed",
            request_id="fixture",
            idempotency_key=plan["idempotency_key"],
            path=plan["path"],
            affected_paths=[plan["path"], plan["index"], plan["daily"]],
            warnings=[],
            recovery=dict(required=False, action=""),
            error_code=None,
            retryable=False,
        )
        self.event("PostToolUse", **tool, tool_response={"structuredContent": receipt})
        self.assertEqual(json.loads(path.read_bytes())["disposition"], "saved")
        self.assertTrue(
            self.native("drain-status", "--home", str(self.profile))["quiescent"]
        )
        plain = self.directory / "directory"
        plain.mkdir()
        self.event(
            "UserPromptSubmit",
            cwd=str(plain),
            session_id="directory-session",
            prompt="Directory work",
        )
        descriptors = [
            json.loads(p.read_bytes())
            for p in (self.profile / "workspaces").glob("*/capture-profile.json")
        ]
        self.assertEqual({v["projectMode"] for v in descriptors}, {"git", "directory"})
        self.assertEqual((self.home / "config.toml").read_bytes(), config)
        self.assertFalse((self.home / "hooks.json").exists())

    def test_claude_owner_preserved_and_codex_keeper_refuses(self):
        owner = self.global_owner(
            default_profile="/unused/claude", excluded_projects=[]
        )
        before = owner.read_bytes()
        self.activate()
        self.assertEqual(owner.read_bytes(), before)
        keeper = self.installed / "skills/commit-capture/scripts/keeper"
        result = subprocess.run(
            ["bash", str(keeper), "--help"],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Codex", result.stderr)
        self.assertEqual(owner.read_bytes(), before)

    def test_global_closed_and_lock_contention_never_delegate_or_deny_ordinary_work(
        self,
    ):
        self.activate()
        for flags in (dict(owner="disabled"), dict(phase="draining")):
            self.global_owner(**flags)
            for event in ("UserPromptSubmit", "Stop", "PreToolUse"):
                output = self.event(event, prompt="work", tool_name="Read")
                self.assertNotIn("decision", output)
                self.assertNotIn(
                    "permissionDecision", output.get("hookSpecificOutput", {})
                )
            denied = self.event(
                "PreToolUse", tool_name="mcp__obsidian_write__obsidian_keeper_save"
            )
            self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
            self.assertEqual(self.states(), [])
        self.global_owner()
        with (self.state / "capture-ownership/admission.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.activation().returncode, 0)
            self.assertIn(
                "busy", json.dumps(self.event("UserPromptSubmit", prompt="work"))
            )
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            self.assertNotEqual(self.activation().returncode, 0)
        self.assertEqual(self.states(), [])

    def test_pending_disable_and_reapply_retain_closed_evidence(self):
        self.activate()
        self.event("UserPromptSubmit", prompt="Retain me")
        before = self.snapshot(self.profile)
        result = self.cli("codex-disable", "--apply", "--verification", VERIFICATION)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(self.record_path().read_bytes())["phase"], "draining"
        )
        self.assertEqual(self.snapshot(self.profile), before)
        self.assertNotEqual(self.activation().returncode, 0)
        self.assertEqual(self.snapshot(self.profile), before)
        self.assertIn("draining", json.dumps(self.event("Stop")))

    def test_disable_stays_disabled_without_legacy_fallback(self):
        self.activate()
        result = self.cli("codex-disable", "--apply", "--verification", VERIFICATION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.record_path().read_bytes())["owner"], "disabled"
        )
        self.assertIn(
            "disabled", json.dumps(self.event("UserPromptSubmit", prompt="work"))
        )
        self.assertEqual(self.states(), [])

    def test_candidate_tamper_and_verifier_tamper_never_execute(self):
        candidate = self.directory / "candidate"
        shutil.copytree(self.bundle, candidate)
        marker = self.directory / "executed"
        executable = candidate / "bin/obsidian-mcp-native"
        executable.write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
        )
        result = self.activation(bundle=str(candidate))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        verifier = (
            self.installed
            / "skills/commit-capture/scripts/lib/obsidian-mcp-client-install"
        )
        verifier.write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
        )
        result = self.activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertIn("verifier", result.stderr)

    def test_profile_tamper_refuses_and_never_uses_claude_alias(self):
        self.activate()
        descriptor = self.profile / "capture-profile.json"
        value = json.loads(descriptor.read_bytes())
        value["host"] = "claude-plugin"
        descriptor.write_text(json.dumps(value))
        output = self.event("UserPromptSubmit", prompt="work")
        self.assertIn("profile", json.dumps(output))
        self.assertEqual(self.states(), [])
        self.assertNotEqual(self.activation().returncode, 0)

    def test_managed_and_unverified_apply_refuse(self):
        self.assertNotEqual(self.activation(delivery="managed").returncode, 0)
        result = self.cli(
            "codex-activate",
            "--bundle",
            str(self.bundle),
            "--release-sha256",
            self.digest,
            "--profile",
            str(self.profile),
            "--codex-home",
            str(self.home),
            "--apply",
            "--create-profile",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.profile.exists())

    def handoff(self, owner="disabled"):
        return self.cli(
            "handoff",
            "--owner",
            owner,
            "--verification",
            VERIFICATION,
            helper=self.installed
            / "skills/commit-capture/scripts/lib/capture-owner.py",
        )

    def test_global_handoff_pending_codex_profile_stays_closed(self):
        self.activate()
        self.event("UserPromptSubmit", prompt="Pending native work")
        retained = self.snapshot(self.profile)
        result = self.handoff()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pending", result.stderr)
        global_record = self.state / "capture-ownership/owner.json"
        self.assertEqual(json.loads(global_record.read_bytes())["phase"], "draining")
        self.assertEqual(self.snapshot(self.profile), retained)
        self.assertIn("global", json.dumps(self.event("Stop")))

    def test_global_handoff_includes_disabled_and_retained_profiles(self):
        self.activate()
        old_profile = self.profile
        self.profile = self.directory / "second-profile"
        self.activate()
        result = self.cli("codex-disable", "--apply", "--verification", VERIFICATION)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record_path().read_bytes())
        self.assertEqual(
            {entry["profile"] for entry in record["retained_profiles"]},
            {str(old_profile), str(self.profile)},
        )
        payload = dict(
            hook_event_name="UserPromptSubmit",
            session_id="late-old-writer",
            turn_id="late-turn",
            cwd=str(self.project),
            prompt="Retained evidence",
        )
        result = self.cli(
            "hook",
            "--home",
            str(old_profile),
            payload=payload,
            helper=self.bundle / "bin/obsidian-mcp-native",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        retained = self.snapshot(old_profile)
        result = self.handoff()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pending", result.stderr)
        self.assertEqual(self.snapshot(old_profile), retained)
        self.assertEqual(
            json.loads(self.record_path().read_bytes())["owner"], "disabled"
        )

    def test_corrupt_codex_inventory_blocks_global_handoff_and_legacy(self):
        self.activate()
        self.record_path().write_text('{"schema": 1, "host": "codex"}')
        result = self.handoff()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            json.loads((self.state / "capture-ownership/owner.json").read_bytes())[
                "phase"
            ],
            "draining",
        )
        self.assertIn(
            "invalid", json.dumps(self.event("UserPromptSubmit", prompt="work"))
        )
        result = subprocess.run(
            [
                "bash",
                str(self.installed / "skills/commit-capture/scripts/keeper"),
                "--help",
            ],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_global_handoff_success_does_not_rewrite_codex_record(self):
        self.activate()
        before = self.record_path().read_bytes()
        result = self.handoff()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.record_path().read_bytes(), before)
        self.assertEqual(json.loads(result.stdout)["owner"], "disabled")

    def test_two_codex_homes_have_independent_selection_and_disabled_state(self):
        self.activate()
        first_path = self.record_path()
        first = first_path.read_bytes()
        self.home = self.directory / "other-codex"
        self.home.mkdir()
        self.env["CODEX_HOME"] = str(self.home)
        self.profile = self.directory / "other-attached"
        self.activate()
        self.assertNotEqual(first_path, self.record_path())
        result = self.cli("codex-disable", "--apply", "--verification", VERIFICATION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(first_path.read_bytes(), first)
        self.env["CODEX_HOME"] = str(self.directory / "normal-codex")
        self.event("UserPromptSubmit", prompt="First home still enabled")
        self.assertEqual(
            len(
                list(
                    (self.directory / "attached/workspaces").glob(
                        "*/capture-state/*.json"
                    )
                )
            ),
            1,
        )
        self.assertEqual(self.states(), [])

    def case_alias(self, path):
        alias = path.with_name(path.name.upper())
        if not alias.exists() or not path.samefile(alias):
            self.skipTest("NOT_APPLICABLE: fixture volume is case-sensitive")
        self.assertNotEqual(str(path.resolve()), str(alias.resolve()))
        return alias

    def assert_home_alias_uses_existing_record(self, alias):
        before = self.record_path().read_bytes()
        self.env["CODEX_HOME"] = str(alias)
        result = self.cli("codex-status")
        self.assertEqual(result.returncode, 0, result.stderr)
        status = json.loads(result.stdout)
        self.assertEqual(status["status"], "configured")
        self.assertEqual(status["codex_home"], str(self.home))
        self.assertEqual(self.record_path().read_bytes(), before)
        result = self.cli(
            "legacy",
            "--host",
            "codex",
            "--",
            "/usr/bin/true",
            helper=self.installed
            / "skills/commit-capture/scripts/lib/capture-owner.py",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no legacy fallback", result.stderr)
        result = self.activation(codex_home=str(alias))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["codex_home"], str(self.home))
        self.assertEqual(len(list(self.record_path().parent.iterdir())), 1)

    def test_actual_case_alias_uses_existing_record_and_refuses_legacy(self):
        alias = self.case_alias(self.home)
        self.activate()
        self.assert_home_alias_uses_existing_record(alias)

    def test_symlink_home_alias_uses_existing_record_and_refuses_legacy(self):
        alias = self.directory / "home-alias"
        alias.symlink_to(self.home, target_is_directory=True)
        self.activate()
        self.assert_home_alias_uses_existing_record(alias)

    def test_profile_same_physical_home_is_rejected_before_native_execution(self):
        profile = self.directory / "attached-home"
        self.native(
            "attach",
            "--host",
            "codex",
            "--scope",
            "user",
            "--home",
            str(profile),
            "--folder",
            "Sessions",
            "--release-sha256",
            self.digest,
        )
        alias = self.case_alias(profile)
        self.home = profile
        self.profile = alias
        before = self.snapshot()
        for apply in (False, True):
            with self.subTest(apply=apply):
                result = self.activation(apply=apply)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("separate from CODEX_HOME", result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_missing_home_keeps_path_identity_without_creating_state(self):
        self.activate()
        missing = self.directory / "not-created-home"
        before = self.snapshot()
        result = self.cli("codex-status", "--codex-home", str(missing))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "dormant")
        self.assertEqual(json.loads(result.stdout)["codex_home"], str(missing))
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(missing.exists())

    def test_corrupt_inventory_on_key_miss_never_falls_back_to_dormant(self):
        self.activate()
        corrupt = self.record_path().with_name("zz-corrupt.json")
        corrupt.write_text("{}")
        corrupt.chmod(0o600)
        other = self.directory / "other-home"
        other.mkdir()
        result = self.cli("codex-status", "--codex-home", str(other))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('"status": "dormant"', result.stdout)

    def test_alias_lookup_rejects_multiple_physical_records(self):
        alias = self.case_alias(self.home)
        self.activate()
        value = json.loads(self.record_path().read_bytes())
        value["codex_home"] = str(alias)
        duplicate = self.record_path().with_name(
            hashlib.sha256(str(alias).encode()).hexdigest() + ".json"
        )
        duplicate.write_text(json.dumps(value))
        duplicate.chmod(0o600)
        third = self.home.with_name(self.home.name.title())
        self.assertTrue(third.samefile(self.home))
        self.assertNotIn(str(third), (str(self.home), str(alias)))
        result = self.cli("codex-status", "--codex-home", str(third))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple", result.stderr)

    def test_alias_lookup_bounds_total_inventory_bytes(self):
        self.activate()
        original = json.loads(self.record_path().read_bytes())
        for index in range(9):
            value = dict(
                original, codex_home=str(self.directory / ("missing-" + str(index)))
            )
            path = self.record_path().with_name(
                hashlib.sha256(value["codex_home"].encode()).hexdigest() + ".json"
            )
            body = json.dumps(value)
            path.write_text(body + " " * (1000000 - len(body)))
            path.chmod(0o600)
        result = self.cli(
            "codex-status", "--codex-home", str(self.directory / "unregistered")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inventory", result.stderr)

    def test_case_sensitive_distinct_home_names_remain_independent(self):
        other = self.home.with_name(self.home.name.upper())
        if other.exists() and other.samefile(self.home):
            self.skipTest("NOT_APPLICABLE: fixture volume is case-insensitive")
        other.mkdir()
        self.activate()
        first_path = self.record_path()
        first = self.record_path().read_bytes()
        result = self.cli("codex-status", "--codex-home", str(other))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "dormant")
        self.assertEqual(self.record_path().read_bytes(), first)
        self.assertEqual(len(list(self.record_path().parent.iterdir())), 1)
        self.home = other
        self.profile = self.directory / "distinct-case-profile"
        self.activate()
        self.assertNotEqual(self.record_path(), first_path)
        self.assertEqual(first_path.read_bytes(), first)
        self.assertEqual(len(list(first_path.parent.iterdir())), 2)

    def test_activation_rechecks_alias_identity_inside_exclusive_lock(self):
        alias = self.case_alias(self.home)
        self.activate()
        path = self.record_path()
        saved = self.directory / "concurrent-record.json"
        path.rename(saved)
        program = """
from contextlib import contextmanager
import runpy, shutil, sys
library, saved, target, *arguments = sys.argv[1:]
runtime = runpy.run_path(library)
main = runtime['codex_main']
namespace = main.__globals__
admission = namespace['admission']
@contextmanager
def published_before_lock(exclusive=False):
    with admission(exclusive=exclusive) as descriptor:
        if exclusive:
            shutil.copy2(saved, target)
        yield descriptor
namespace['admission'] = published_before_lock
sys.argv = [library, *arguments]
sys.exit(main())
"""
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                "-c",
                program,
                str(
                    self.installed
                    / "skills/commit-capture/scripts/lib/capture-owner.py"
                ),
                str(saved),
                str(path),
                "codex-activate",
                "--codex-home",
                str(alias),
                "--profile",
                str(self.profile),
                "--bundle",
                str(self.bundle),
                "--release-sha256",
                self.digest,
                "--apply",
                "--verification",
                VERIFICATION,
            ],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=40,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["codex_home"], str(self.home))
        self.assertEqual(len(list(path.parent.iterdir())), 1)

    def test_interrupted_profile_change_retains_both_and_reapply_drains_old(self):
        self.activate()
        self.event("UserPromptSubmit", prompt="Old pending evidence")
        old_profile = self.profile
        original = self.snapshot(old_profile)
        self.profile = self.directory / "replacement-profile"
        result = self.activation()
        self.assertNotEqual(result.returncode, 0)
        record = json.loads(self.record_path().read_bytes())
        self.assertEqual(record["phase"], "draining")
        self.assertEqual(
            {entry["profile"] for entry in record["retained_profiles"]},
            {str(old_profile), str(self.profile)},
        )
        self.assertEqual(self.snapshot(old_profile), original)
        self.assertNotEqual(self.activation().returncode, 0)
        result = self.cli("codex-disable", "--apply", "--verification", VERIFICATION)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(old_profile), original)
        self.assertEqual(
            json.loads(self.record_path().read_bytes())["phase"], "draining"
        )

    def test_process_interruption_after_draining_requires_verified_reapply(self):
        self.activate()
        old = self.profile
        replacement = self.directory / "replacement-profile"
        program = """
import os, runpy, sys
library, *arguments = sys.argv[1:]
runtime = runpy.run_path(library)
function = runtime['codex_main']
namespace = function.__globals__
write = namespace['write']
def interrupted(path, value):
    write(path, value)
    if value.get('host') == 'codex' and value.get('phase') == 'draining':
        os._exit(73)
namespace['write'] = interrupted
sys.argv = [library, *arguments]
sys.exit(function())
"""
        arguments = [
            "codex-activate",
            "--bundle",
            str(self.bundle),
            "--release-sha256",
            self.digest,
            "--profile",
            str(replacement),
            "--create-profile",
            "--codex-home",
            str(self.home),
            "--apply",
            "--verification",
            VERIFICATION,
        ]
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                "-c",
                program,
                str(
                    self.installed
                    / "skills/commit-capture/scripts/lib/capture-owner.py"
                ),
                *arguments,
            ],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 73, result.stderr)
        closed = self.record_path().read_bytes()
        record = json.loads(closed)
        self.assertEqual(record["phase"], "draining")
        self.assertEqual(
            {entry["profile"] for entry in record["retained_profiles"]},
            {str(old), str(replacement)},
        )
        result = self.cli(*arguments[:-2])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.record_path().read_bytes(), closed)
        self.profile = replacement
        self.activate()
        self.assertEqual(json.loads(self.record_path().read_bytes())["phase"], "stable")
        self.assertTrue((old / "capture-profile.json").exists())

    def test_retained_031_runtime_rejected_as_unsupported(self):
        source = self.directory / "old-source"
        shutil.copytree(ROOT / "packages/client", source / "packages/client")
        (source / "scripts").mkdir()
        shutil.copy2(
            ROOT / "scripts/pack-obsidian-mcp-client.py",
            source / "scripts/pack-obsidian-mcp-client.py",
        )
        (source / "packages/mcp-server").mkdir()
        shutil.copy2(
            ROOT / "packages/mcp-server/contract.json",
            source / "packages/mcp-server/contract.json",
        )
        old = self.directory / "old-client"
        result = self.cli(
            "--output", str(old), helper=source / "scripts/pack-obsidian-mcp-client.py"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        digest = hashlib.sha256((old / "release.json").read_bytes()).hexdigest()
        result = self.activation(bundle=str(old), release_sha256=digest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported", result.stderr)
        self.assertFalse(self.profile.exists())

    def test_installed_hook_command_is_root_safe_and_ignores_path_candidates(self):
        hooks = json.loads((self.installed / "hooks/hooks.json").read_bytes())["hooks"]
        command = hooks["UserPromptSubmit"][0]["hooks"][0]["command"]
        self.activate()
        rogue = self.directory / "rogue"
        rogue.mkdir()
        marker = self.directory / "path-executed"
        (rogue / "python3").write_text(
            "#!/bin/sh\ntouch " + shlex.quote(str(marker)) + "\n"
        )
        (rogue / "python3").chmod(0o700)
        env = dict(
            self.env,
            PLUGIN_ROOT=str(self.installed),
            PATH=str(rogue) + ":" + self.env["PATH"],
        )
        event = dict(
            hook_event_name="UserPromptSubmit",
            session_id="hook-native",
            turn_id="hook-turn",
            cwd=str(self.project),
            prompt="Actual installed hook",
        )
        result = subprocess.run(
            ["/bin/sh", "-c", command],
            input=json.dumps(event),
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hook-turn", result.stdout)
        self.assertFalse(marker.exists())

    def test_native_aliases_are_not_translated(self):
        self.activate()
        self.event("UserPromptSubmit", prompt="Native aliases")
        path = self.states()[0]
        before = path.read_bytes()
        for alias in (
            "mcp__obsidian-write__obsidian_keeper_save",
            "obsidian_keeper_save",
        ):
            self.event(
                "PostToolUse",
                tool_name=alias,
                tool_use_id="not-native",
                tool_input={},
                tool_response={"structuredContent": {"status": "committed"}},
            )
            self.assertEqual(path.read_bytes(), before)

    def test_existing_profile_and_disable_previews_are_read_only(self):
        self.native(
            "attach",
            "--host",
            "codex",
            "--scope",
            "user",
            "--home",
            str(self.profile),
            "--folder",
            "Sessions",
            "--daily-folder",
            "Daily",
            "--release-sha256",
            self.digest,
        )
        before = self.snapshot()
        result = self.activation(apply=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.activate()
        before = self.snapshot()
        result = self.cli("codex-disable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_installed_release_verified_against_external_digest_and_trust_record(self):
        prefix = self.directory / "runtime-prefix"
        result = self.cli(
            "--prefix",
            str(prefix),
            "--bundle",
            str(self.bundle),
            "--release-sha256",
            self.digest,
            helper=self.installed
            / "skills/commit-capture/scripts/lib/obsidian-mcp-client-install",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        installed_bundle = (prefix / "current").resolve()
        result = self.activation(bundle=str(installed_bundle))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.event("UserPromptSubmit", prompt="Installed release capture")
        self.assertEqual(len(self.states()), 1)
        trust = installed_bundle / ".trust.json"
        value = json.loads(trust.read_bytes())
        value["externalReleaseJsonSha256"] = "f" * 64
        trust.write_text(json.dumps(value))
        before = self.snapshot(self.profile)
        self.assertIn(
            "verification",
            json.dumps(
                self.event("UserPromptSubmit", prompt="Tamper", turn_id="different")
            ),
        )
        self.assertEqual(self.snapshot(self.profile), before)

    def test_runtime_tamper_after_activation_is_not_executed_by_hook_or_disable(self):
        candidate = self.directory / "candidate"
        shutil.copytree(self.bundle, candidate)
        result = self.activation(bundle=str(candidate))
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.directory / "native-executed"
        (candidate / "bin/obsidian-mcp-native").write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
        )
        output = self.event("UserPromptSubmit", prompt="work")
        self.assertIn("verification", json.dumps(output))
        self.assertEqual(self.states(), [])
        self.assertFalse(marker.exists())
        result = self.cli("codex-disable", "--apply", "--verification", VERIFICATION)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertEqual(
            json.loads(self.record_path().read_bytes())["phase"], "draining"
        )

    def test_initial_existing_profile_interpreter_is_never_executed(self):
        self.native(
            "attach",
            "--host",
            "codex",
            "--scope",
            "user",
            "--home",
            str(self.profile),
            "--folder",
            "Sessions",
            "--release-sha256",
            self.digest,
        )
        descriptor = self.profile / "capture-profile.json"
        original = json.loads(descriptor.read_bytes())
        for apply in (False, True):
            with self.subTest(apply=apply):
                marker = self.directory / ("initial-interpreter-executed-" + str(apply))
                rogue = self.directory / ("untrusted-python-" + str(apply))
                rogue.write_text(
                    "#!/bin/sh\ntouch " + shlex.quote(str(marker)) + "\nexit 1\n"
                )
                rogue.chmod(0o700)
                descriptor.write_text(json.dumps(dict(original, python=str(rogue))))
                before = self.snapshot()
                result = self.activation(apply=apply)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(
                    marker.exists(), "unregistered profile interpreter was executed"
                )
                self.assertIn("trusted launcher", result.stderr)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(self.record_path().exists())

    def test_reapply_rejects_changed_profile_interpreter_before_execution(self):
        self.activate()
        marker = self.directory / "python-executed"
        rogue = self.directory / "rogue-python"
        rogue.write_text("#!/bin/sh\ntouch " + shlex.quote(str(marker)) + "\n")
        rogue.chmod(0o700)
        path = self.profile / "capture-profile.json"
        value = json.loads(path.read_bytes())
        value["python"] = str(rogue)
        path.write_text(json.dumps(value))
        result = self.activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertIn("profile", result.stderr)

    def test_legacy_pending_evidence_blocks_activation_without_deleting_it(self):
        pending = self.state / "capture-ownership/pending-commits/unresolved.json"
        pending.parent.mkdir(parents=True)
        pending.write_text(
            json.dumps(
                dict(hash="a" * 40, vault=str(self.directory), target="Missing.md")
            )
        )
        pending.chmod(0o600)
        before = pending.read_bytes()
        result = self.activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("legacy", result.stderr)
        self.assertEqual(pending.read_bytes(), before)
        self.assertEqual(
            json.loads(self.record_path().read_bytes())["phase"], "draining"
        )
        self.assertFalse(self.profile.exists())


if __name__ == "__main__":
    unittest.main()
