#!/usr/bin/env python3
"""Installed-package admission against the packed public engine, without providers."""

import array
import fcntl
import hashlib
import json
import os
import runpy
import select
import signal
import time
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import termios
import unittest


ROOT = Path(__file__).resolve().parents[1]
PUBLIC_HEAD = "f511884950777179de8e5bc47a2a5dd2bca52b7c"
VERIFICATION = "legacy-writers-stopped-and-history-inspected"
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"


class GuidanceCompatibilityTest(unittest.TestCase):
    prefixes = (
        "Prepare the pending capture: pipe JSON ",
        "Prepare the pending commit before another commit: pipe JSON ",
    )

    def setUp(self):
        self.runtime = runpy.run_path(str(ROOT / "scripts/lib/capture-owner.py"))
        self.binding = {"python": "/fixture/python", "bundle": "/fixture/bundle"}
        self.arguments = [
            "prepare",
            "--home", "/fixture/profile",
            "--session", "a" * 64,
            "--commit", "b" * 64,
        ]

    def guidance(self, prefix, launcher, arguments):
        return (
            prefix + '{"context":["fixture context"]} to '
            + shlex.join([*launcher, *arguments])
            + ", then call mcp__obsidian_write__obsidian_daily_append."
        )

    def test_both_preparation_prefixes_rewrite_to_authorized_executor(self):
        launcher = ["/fixture/python", "/fixture/bundle/bin/obsidian-mcp-native"]
        for prefix in self.prefixes:
            with self.subTest(prefix=prefix):
                text = self.guidance(prefix, launcher, self.arguments)
                rewritten = self.runtime["codex_guard_text"](
                    text, "fixture-authorization", self.binding
                )
                before, command = rewritten.split(" to ", 1)
                command, after = command.split(", then call ", 1)
                self.assertEqual(before, prefix + '{"context":["fixture context"]}')
                self.assertEqual(after, "mcp__obsidian_write__obsidian_daily_append.")
                self.assertEqual(
                    shlex.split(command),
                    [
                        "/usr/bin/python3", "-I", "-B",
                        str(ROOT / "packages/codex/scripts/capture.py"),
                        "codex-execute", "--authorization", "fixture-authorization",
                        "--", *self.arguments,
                    ],
                )

    def test_both_preparation_prefixes_reject_unknown_launchers_and_operations(self):
        native = "/fixture/bundle/bin/obsidian-mcp-native"
        for prefix in self.prefixes:
            for launcher, arguments, error in (
                (["/unknown/python", native], self.arguments, "launcher"),
                (["/fixture/python", "/unknown/native"], self.arguments, "launcher"),
                (["/fixture/python", native], ["unknown"], "unsupported"),
                (["/fixture/python", native], [
                    "status", "--home", "/fixture/profile", "--session", "a" * 64,
                ], "operation mismatch"),
            ):
                with self.subTest(prefix=prefix, launcher=launcher, arguments=arguments):
                    with self.assertRaisesRegex(self.runtime["OwnershipError"], error):
                        self.runtime["codex_guard_text"](
                            self.guidance(prefix, launcher, arguments),
                            "fixture-authorization",
                            self.binding,
                        )


class PackagedGuidanceCompatibilityTest(GuidanceCompatibilityTest):
    def setUp(self):
        super().setUp()
        self.runtime = runpy.run_path(str(
            ROOT / "packages/codex/skills/commit-capture/scripts/lib/capture-owner.py"
        ))


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
        return [
            path
            for path in (self.profile / "workspaces").glob("*/capture-state/*.json")
            if path.name != "active.json"
        ]

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

    def installed_hook(self, event, raw, tool=None, environment=None):
        import re

        groups = json.loads((self.installed / "hooks/hooks.json").read_bytes())[
            "hooks"
        ][event]
        if tool is not None:
            groups = [
                group
                for group in groups
                if re.fullmatch(group.get("matcher", ".*"), tool)
            ]
        self.assertEqual(len(groups), 1)
        command = groups[0]["hooks"][0]["command"]
        env = dict(self.env, PLUGIN_ROOT=str(self.installed))
        for key, value in (environment or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        result = subprocess.run(
            ["/bin/sh", "-c", command],
            input=raw,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        return json.loads(result.stdout)

    def test_corrupt_record_denies_actual_owned_pretool_before_home_lookup(self):
        self.activate()
        self.record_path().write_text("{}")
        for tool in (
            "mcp__obsidian_write__obsidian_keeper_save",
            "mcp__obsidian_write__obsidian_daily_append",
        ):
            with self.subTest(tool=tool):
                output = self.installed_hook(
                    "PreToolUse",
                    json.dumps(
                        dict(
                            hook_event_name="PreToolUse",
                            tool_name=tool,
                            cwd=str(self.project),
                        )
                    ),
                    tool=tool,
                )
                self.assertEqual(
                    output.get("hookSpecificOutput", {}).get("permissionDecision"),
                    "deny",
                )
        output = self.installed_hook(
            "PreToolUse",
            json.dumps(
                dict(
                    hook_event_name="PreToolUse",
                    tool_name="Bash",
                    cwd=str(self.project),
                )
            ),
            tool="Bash",
        )
        self.assertNotIn("permissionDecision", output.get("hookSpecificOutput", {}))

    def test_list_hook_payload_never_raises_in_error_handler(self):
        self.activate()
        output = self.installed_hook(
            "PreToolUse", "[]", tool="mcp__obsidian_write__obsidian_keeper_save"
        )
        self.assertEqual(
            output.get("hookSpecificOutput", {}).get("permissionDecision"), "deny"
        )

    def test_admission_failures_deny_owned_writes_and_preserve_ordinary_work(self):
        self.activate()
        record = self.record_path()
        original = record.read_bytes()
        private = self.directory / "saved-activation.json"
        private.write_bytes(original)
        private.chmod(0o600)
        for failure in (
            "symlink",
            "permissions",
            "global-disabled",
            "global-draining",
            "xdg-invalid",
            "home-invalid",
            "default-home-invalid",
            "alias-inventory",
            "runtime",
        ):
            with self.subTest(failure=failure):
                environment = {}
                if failure == "symlink":
                    record.rename(self.directory / "removed-record.json")
                    record.symlink_to(private)
                elif failure == "permissions":
                    record.chmod(0o644)
                elif failure == "global-disabled":
                    self.global_owner(owner="disabled")
                elif failure == "global-draining":
                    self.global_owner(phase="draining")
                elif failure == "xdg-invalid":
                    environment["XDG_STATE_HOME"] = ""
                elif failure == "home-invalid":
                    environment["CODEX_HOME"] = ""
                elif failure == "default-home-invalid":
                    environment.update(HOME="", CODEX_HOME=None, XDG_STATE_HOME=None)
                elif failure == "alias-inventory":
                    environment["CODEX_HOME"] = str(
                        self.directory / "unregistered-home"
                    )
                    corrupt = record.with_name("invalid.json")
                    corrupt.write_text("{}")
                    corrupt.chmod(0o600)
                elif failure == "runtime":
                    descriptor = self.profile / "capture-profile.json"
                    profile_bytes = descriptor.read_bytes()
                    descriptor.write_text("{}")
                for tool in ("mcp__obsidian_write__obsidian_keeper_save", "Bash"):
                    payload = json.dumps(
                        dict(
                            hook_event_name="PreToolUse",
                            tool_name=tool,
                            cwd=str(self.project),
                        )
                    )
                    output = self.installed_hook(
                        "PreToolUse", payload, tool=tool, environment=environment
                    )
                    decision = output.get("hookSpecificOutput", {}).get(
                        "permissionDecision"
                    )
                    self.assertEqual(
                        decision, "deny" if tool.startswith("mcp__") else None
                    )
                for event in ("UserPromptSubmit", "Stop"):
                    output = self.installed_hook(
                        event,
                        json.dumps(
                            dict(
                                hook_event_name=event,
                                prompt="ordinary work",
                                cwd=str(self.project),
                            )
                        ),
                        environment=environment,
                    )
                    self.assertNotIn("decision", output)
                    self.assertNotEqual(output.get("continue"), False)
                if failure == "symlink":
                    record.unlink()
                    (self.directory / "removed-record.json").rename(record)
                elif failure == "permissions":
                    record.chmod(0o600)
                elif failure.startswith("global-"):
                    self.global_owner()
                elif failure == "alias-inventory":
                    corrupt.unlink()
                elif failure == "runtime":
                    descriptor.write_bytes(profile_bytes)

    def test_malformed_owned_inputs_deny_and_ordinary_handlers_stay_advisory(self):
        self.activate()
        for raw in (
            "[]",
            "null",
            "false",
            '"text"',
            "{",
            '{"tool_name":"Bash","tool_name":"mcp__obsidian_write__obsidian_keeper_save"}',
            "[" * 2000 + "]" * 2000,
            json.dumps(
                dict(
                    tool_name="mcp__obsidian_write__obsidian_keeper_save",
                    tool_input="x" * 262145,
                )
            ),
        ):
            with self.subTest(raw=raw[:80]):
                owned = self.installed_hook(
                    "PreToolUse", raw, tool="mcp__obsidian_write__obsidian_keeper_save"
                )
                self.assertEqual(
                    owned.get("hookSpecificOutput", {}).get("permissionDecision"),
                    "deny",
                )
                ordinary = self.installed_hook("PreToolUse", raw, tool="Bash")
                self.assertNotIn(
                    "permissionDecision", ordinary.get("hookSpecificOutput", {})
                )
                for event in ("UserPromptSubmit", "Stop"):
                    output = self.installed_hook(event, raw)
                    self.assertNotIn("decision", output)
                    self.assertNotEqual(output.get("continue"), False)

    def test_hook_error_identity_resets_between_calls_and_unknown_input_denies(self):
        self.activate()
        self.record_path().write_text("{}")
        program = """
from contextlib import redirect_stdout
import io, json, runpy, sys
library = sys.argv[1]
main = runpy.run_path(library)['codex_main']
results = []
for value in ({'tool_name': 'mcp__obsidian_write__obsidian_keeper_save'}, {'tool_name': 'Bash'}, []):
    sys.argv = [library, 'codex-route', '--event', 'PreToolUse']
    sys.stdin = io.TextIOWrapper(io.BytesIO(json.dumps(value).encode()))
    output = io.StringIO()
    with redirect_stdout(output):
        assert main() == 0
    results.append(json.loads(output.getvalue()))
print(json.dumps(results))
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
            ],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = json.loads(result.stdout)
        self.assertEqual(
            [
                output.get("hookSpecificOutput", {}).get("permissionDecision")
                for output in outputs
            ],
            ["deny", None, "deny"],
        )

    def guarded_fixture(self, commit=False, commit_command="git commit -m fixture"):
        runtime = self.directory / "executor-runtime"
        shutil.copytree(self.bundle, runtime)
        result = self.activation(bundle=str(runtime))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.env.update(
            GIT_AUTHOR_NAME="Fixture",
            GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Fixture",
            GIT_COMMITTER_EMAIL="fixture@example.invalid",
        )
        for arguments in (
            ("config", "commit.gpgsign", "false"),
            ("config", "core.hooksPath", str(self.directory / "no-hooks")),
            ("remote", "add", "origin", "https://github.com/nhangen/guard-fixture.git"),
        ):
            subprocess.run(
                ["git", "-C", str(self.project), *arguments],
                env=self.env,
                check=True,
                capture_output=True,
            )
        prompt = self.event("UserPromptSubmit", prompt="Guarded fixture work")
        if not commit:
            text = prompt["hookSpecificOutput"]["additionalContext"]
            return runtime, text.split("acknowledge explicitly with ", 1)[1].split(
                " (or user_requested_no_capture)", 1
            )[0]
        (self.project / "file.txt").write_text("Fixture work\n")
        subprocess.run(
            ["git", "-C", str(self.project), "add", "file.txt"],
            env=self.env,
            check=True,
            capture_output=True,
        )
        output = self.event(
            "PreToolUse",
            tool_name="Bash",
            tool_use_id="guard-commit",
            tool_input={"command": commit_command},
        )
        return runtime, output["hookSpecificOutput"]["updatedInput"]["command"]

    def run_emitted(self, command, payload=None):
        return subprocess.run(
            shlex.split(command),
            input=payload,
            env=self.env,
            cwd=self.project,
            capture_output=True,
            text=True,
            timeout=40,
        )

    def run_emitted_open_stdin(self, command, timeout=8):
        process = subprocess.Popen(
            shlex.split(command),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            cwd=self.project,
            start_new_session=True,
        )
        try:
            process.wait(timeout=timeout)
            self.assertFalse(process.stdin.closed)
            return subprocess.CompletedProcess(
                process.args,
                process.returncode,
                process.stdout.read().decode(),
                process.stderr.read().decode(),
            )
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def guarded_prepare_fixture(self):
        _, command = self.guarded_fixture(commit=True)
        result = self.run_emitted(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.event(
            "PostToolUse",
            tool_name="Bash",
            tool_use_id="guard-commit",
            tool_input={"command": command},
            tool_response=result.stdout,
        )
        return (
            output["hookSpecificOutput"]["additionalContext"]
            .split(" to ", 1)[1]
            .split(", then call", 1)[0]
        )

    def test_commit_message_with_executor_name_is_intercepted(self):
        _, command = self.guarded_fixture(
            commit=True, commit_command="git commit -m fix-codex-execute"
        )
        self.assertTrue(json.loads(self.states()[0].read_bytes())["snapshots"])
        result = self.run_emitted(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        subject = subprocess.check_output(
            ["git", "-C", str(self.project), "log", "-1", "--format=%s"],
            env=self.env,
            text=True,
        ).strip()
        self.assertEqual(subject, "fix-codex-execute")

    def test_guarded_executor_completes_with_stdin_producer_still_open(self):
        _, command = self.guarded_fixture(commit=True)
        result = self.run_emitted_open_stdin(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture", result.stdout)
        self.assertEqual(
            subprocess.check_output(
                ["git", "-C", str(self.project), "log", "-1", "--format=%s"],
                env=self.env,
                text=True,
            ).strip(),
            "fixture",
        )

    def test_guarded_recovery_completes_with_stdin_producer_still_open(self):
        _, command = self.guarded_fixture()
        result = self.run_emitted_open_stdin(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.states()[0].read_bytes())
        self.assertEqual(state["disposition"], "skipped_by_policy")

    def test_guarded_executor_preserves_git_stdin(self):
        _, command = self.guarded_fixture(commit=True, commit_command="git commit -F -")
        result = self.run_emitted(command, "Message from executor stdin\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            subprocess.check_output(
                ["git", "-C", str(self.project), "log", "-1", "--format=%s"],
                env=self.env,
                text=True,
            ).strip(),
            "Message from executor stdin",
        )

    def test_guarded_prepare_bounds_open_producer_time_and_input_bytes(self):
        command = self.guarded_prepare_fixture()
        before = self.snapshot(self.profile)
        started = time.monotonic()
        result = self.run_emitted_open_stdin(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("input timed out", result.stderr)
        self.assertLess(time.monotonic() - started, 8)
        self.assertEqual(self.snapshot(self.profile), before)
        result = self.run_emitted(command, "x" * 262145)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("input exceeds", result.stderr)
        self.assertEqual(self.snapshot(self.profile), before)

    def test_emitted_executor_rechecks_runtime_before_execution(self):
        runtime, command = self.guarded_fixture(commit=True)
        marker = self.directory / "executor-unverified"
        (runtime / "bin/obsidian-mcp-native").write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
        )
        before = self.snapshot(self.profile)
        result = self.run_emitted(command)
        self.assertFalse(marker.exists(), "emitted executor ran unverified native code")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(self.profile), before)

    def test_emitted_recovery_rechecks_runtime_before_execution(self):
        runtime, command = self.guarded_fixture()
        marker = self.directory / "recovery-unverified"
        (runtime / "bin/obsidian-mcp-native").write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
        )
        before = self.snapshot(self.profile)
        result = self.run_emitted(command)
        self.assertFalse(marker.exists(), "emitted recovery ran unverified native code")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(self.profile), before)

    def test_guarded_commit_roundtrip_preparation_and_receipt(self):
        _, command = self.guarded_fixture(commit=True)
        self.assertIn("codex-execute", command)
        self.assertIn("-I", shlex.split(command))
        result = self.run_emitted(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture", result.stdout)
        repeated = self.run_emitted(command)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        count = subprocess.check_output(
            ["git", "-C", str(self.project), "rev-list", "--count", "HEAD"],
            env=self.env,
            text=True,
        ).strip()
        self.assertEqual(count, "1")
        output = self.event(
            "PostToolUse",
            tool_name="Bash",
            tool_use_id="guard-commit",
            tool_input={"command": command},
            tool_response=result.stdout,
        )
        state_path = self.states()[0]
        state = json.loads(state_path.read_bytes())
        self.assertEqual(len(state["commits"]), 1)
        self.assertEqual(state["snapshots"], {})
        guidance = output["hookSpecificOutput"]["additionalContext"]
        prepare = guidance.split(" to ", 1)[1].split(", then call", 1)[0]
        self.assertIn("codex-execute", prepare)
        prepared = self.run_emitted(prepare, json.dumps({"context": ["Fixture fact"]}))
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        arguments = json.loads(prepared.stdout)["arguments"]
        tool = dict(
            tool_name="mcp__obsidian_write__obsidian_daily_append",
            tool_use_id="guard-receipt",
            tool_input=arguments,
        )
        self.assertEqual(self.event("PreToolUse", **tool), {})
        receipt = dict(
            status="committed",
            request_id="fixture",
            idempotency_key=arguments["idempotency_key"],
            path=arguments["target_path"],
            affected_paths=[arguments["target_path"]],
            warnings=[],
            recovery=dict(required=False, action=""),
            error_code=None,
            retryable=False,
        )
        self.event("PostToolUse", **tool, tool_response={"structuredContent": receipt})
        state = json.loads(state_path.read_bytes())
        self.assertEqual(next(iter(state["commits"].values()))["status"], "committed")

    def test_guarded_failed_commit_preserves_exit_and_stderr(self):
        _, command = self.guarded_fixture(commit=True)
        hooks = self.directory / "no-hooks"
        hooks.mkdir()
        hook = hooks / "pre-commit"
        hook.write_text("#!/bin/sh\nprintf 'fixture-rejection\\n' >&2\nexit 7\n")
        hook.chmod(0o700)
        result = self.run_emitted(command)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("fixture-rejection", result.stderr)
        self.event(
            "PostToolUse",
            tool_name="Bash",
            tool_use_id="guard-commit",
            tool_input={"command": command},
            tool_response=result.stderr,
        )
        state = json.loads(self.states()[0].read_bytes())
        self.assertEqual(state["snapshots"], {})
        self.assertEqual(state["commits"], {})

    def test_guarded_recovery_skip_and_late_admission_changes(self):
        _, command = self.guarded_fixture()
        record_path = self.record_path()
        original = record_path.read_bytes()
        before = self.snapshot(self.profile)
        for failure in (
            "disabled",
            "draining",
            "generation",
            "delivery",
            "global",
            "global-generation",
            "excluded",
            "binding",
        ):
            with self.subTest(failure=failure):
                record = json.loads(original)
                if failure == "disabled":
                    record["owner"] = "disabled"
                elif failure == "draining":
                    record["phase"] = "draining"
                elif failure == "generation":
                    record["generation"] += 1
                elif failure == "delivery":
                    record["delivery"] = "managed"
                elif failure == "binding":
                    record["profile"] = str(self.directory / "retargeted")
                    record["retained_profiles"].append(
                        {
                            key: record[key]
                            for key in (
                                "profile",
                                "bundle",
                                "externalReleaseSha256",
                                "releaseId",
                                "python",
                            )
                        }
                    )
                elif failure == "global":
                    self.global_owner(owner="disabled")
                elif failure == "global-generation":
                    self.global_owner()
                elif failure == "excluded":
                    self.global_owner(
                        generation=0, excluded_projects=[str(self.project)]
                    )
                record_path.write_text(json.dumps(record))
                result = self.run_emitted(command)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot(self.profile), before)
                record_path.write_bytes(original)
                (self.state / "capture-ownership/owner.json").unlink(missing_ok=True)
        result = self.run_emitted(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.states()[0].read_bytes())["disposition"],
            "skipped_by_policy",
        )

    def test_guarded_session_retry_and_request_keep_frozen_arguments(self):
        _, command = self.guarded_fixture()
        path = self.states()[0]
        plan = json.loads(path.read_bytes())["session_save"]
        arguments = dict(
            title=plan["title"],
            folder_hint=plan["folder"],
            body=json.dumps(
                {
                    "reason": "Frozen facts with request --home and quoted JSON",
                    "wrapped": shlex.join(
                        [
                            str(Path(sys.executable).resolve()),
                            str(
                                self.directory
                                / "executor-runtime/bin/obsidian-mcp-native"
                            ),
                            "request",
                        ]
                    ),
                }
            ),
            resolved=True,
            session_link_date=plan["date"],
            idempotency_key=plan["idempotency_key"],
        )
        tool = dict(
            tool_name="mcp__obsidian_write__obsidian_keeper_save",
            tool_use_id="guard-session",
            tool_input=arguments,
        )
        self.event("PreToolUse", **tool)
        receipt = dict(
            status="partial",
            request_id="fixture",
            idempotency_key=plan["idempotency_key"],
            path=plan["path"],
            affected_paths=[plan["path"]],
            warnings=[],
            recovery=dict(required=True, action="inspect fixture"),
            error_code="PARTIAL",
            retryable=True,
        )
        self.event("PostToolUse", **tool, tool_response={"structuredContent": receipt})
        output = self.event("Stop", stop_hook_active=True)
        text = output["systemMessage"]
        retry = text.split("authorize an exact retry with ", 1)[1].split(
            ". Use the returned arguments", 1
        )[0]
        self.assertIn("codex-execute", retry)
        retried = self.run_emitted(retry)
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertEqual(json.loads(retried.stdout), arguments)
        output = self.event("Stop", stop_hook_active=True)
        request = (
            output["systemMessage"]
            .split("Retrieve the frozen keeper save arguments with ", 1)[1]
            .split("; call ", 1)[0]
        )
        requested = self.run_emitted(request)
        self.assertEqual(requested.returncode, 0, requested.stderr)
        self.assertEqual(json.loads(requested.stdout), arguments)
        self.assertEqual(json.loads(path.read_bytes())["disposition"], "pending")

    def test_guard_rejects_unknown_duplicate_and_retargeted_native_arguments(self):
        _, command = self.guarded_fixture()
        words = shlex.split(command)
        boundary = words.index("--")
        prefix, native = words[: boundary + 1], words[boundary + 1 :]
        before = self.snapshot(self.profile)
        malformed = [
            ["run", *native[1:]],
            [*native, "--bundle", str(self.bundle)],
            [*native, "--reason", "no_meaningful_work"],
            [*native[:-1], "no_meaningful_work; touch fixture-marker"],
            [*native, ";", "touch", "fixture-marker"],
            [native[0], "--home", str(self.directory), *native[3:]],
            [native[0], *native[1:3], "--session", "f" * 64, *native[5:]],
        ]
        for arguments in malformed:
            with self.subTest(arguments=arguments):
                result = self.run_emitted(shlex.join([*prefix, *arguments]))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot(self.profile), before)
                self.assertFalse((self.project / "fixture-marker").exists())

    def test_guard_rejects_profile_and_verifier_changes_after_emission(self):
        _, command = self.guarded_fixture()
        before = self.snapshot(self.profile)
        profile = self.profile / "capture-profile.json"
        descriptor = profile.read_bytes()
        value = json.loads(descriptor)
        value["python"] = "/untrusted/python"
        profile.write_text(json.dumps(value))
        result = self.run_emitted(command)
        self.assertNotEqual(result.returncode, 0)
        profile.write_bytes(descriptor)
        verifier = (
            self.installed
            / "skills/commit-capture/scripts/lib/obsidian-mcp-client-install"
        )
        marker = self.directory / "verifier-executed"
        verifier.write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
        )
        result = self.run_emitted(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertEqual(self.snapshot(self.profile), before)

    def test_guard_refuses_after_failed_disable_and_global_handoff(self):
        _, command = self.guarded_fixture(commit=True)
        before = self.snapshot(self.profile)
        result = self.cli("codex-disable", "--apply", "--verification", VERIFICATION)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(self.record_path().read_bytes())["phase"], "draining"
        )
        result = self.run_emitted(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(self.profile), before)
        result = self.handoff()
        self.assertNotEqual(result.returncode, 0)
        result = self.run_emitted(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(self.profile), before)

    def test_guard_holds_shared_lease_during_long_native_commit(self):
        _, command = self.guarded_fixture(commit=True)
        hooks = self.directory / "no-hooks"
        hooks.mkdir()
        captured = self.directory / "admission-attempt.txt"
        library = self.installed / "skills/commit-capture/scripts/lib/capture-owner.py"
        attempt = shlex.join(
            [
                "/usr/bin/python3",
                "-I",
                "-B",
                str(library),
                "handoff",
                "--owner",
                "disabled",
                "--verification",
                VERIFICATION,
            ]
        )
        hook = hooks / "pre-commit"
        hook.write_text(
            "#!/bin/sh\n"
            + attempt
            + " >"
            + shlex.quote(str(captured))
            + ' 2>&1\nresult=$?\n[ "$result" -ne 0 ] || exit 71\n/usr/bin/grep -q busy '
            + shlex.quote(str(captured))
            + " || exit 72\n/bin/sleep 31\nprintf 'long-fixture-check\\n' >&2\n"
        )
        hook.chmod(0o700)
        result = self.run_emitted(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("long-fixture-check", result.stderr)
        self.assertIn("busy", captured.read_text())

    def assert_guarded_exit_stops_descendants(self, hook_exit):
        _, command = self.guarded_fixture(commit=True)
        hooks = self.directory / "no-hooks"
        hooks.mkdir()
        started = self.directory / "background-group"
        release = self.directory / "release-background"
        marker = self.directory / "background-continued"
        hook = hooks / "pre-commit"
        hook.write_text(
            "#!/bin/sh\n(\n/bin/ps -o pgid= -p $$ > "
            + shlex.quote(str(started))
            + "\nwhile [ ! -e "
            + shlex.quote(str(release))
            + " ]; do /bin/sleep 0.02; done\n/usr/bin/touch "
            + shlex.quote(str(marker))
            + "\n) </dev/null >/dev/null 2>&1 &\nwhile [ ! -s "
            + shlex.quote(str(started))
            + " ]; do /bin/sleep 0.02; done\nprintf 'background-fixture\\n' >&2\nexit "
            + str(hook_exit)
            + "\n"
        )
        hook.chmod(0o700)
        group = None
        try:
            result = self.run_emitted(command)
            self.assertTrue(started.exists())
            group = int(started.read_text().strip())
            self.assertNotEqual(group, os.getpgrp())
            self.assertEqual(
                result.returncode, 0 if hook_exit == 0 else 1, result.stderr
            )
            self.assertIn("background-fixture", result.stderr)
            if hook_exit == 0:
                self.assertIn("fixture", result.stdout)
            with (self.state / "capture-ownership/admission.lock").open("r+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                release.touch()
                deadline = time.monotonic() + 1
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(
                    marker.exists(),
                    "owned descendant continued after admission was released",
                )
        finally:
            if group is not None:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_guard_success_stops_background_descendants_before_releasing_lease(self):
        self.assert_guarded_exit_stops_descendants(0)

    def test_guard_nonzero_stops_background_descendants_before_releasing_lease(self):
        self.assert_guarded_exit_stops_descendants(7)

    def test_detached_git_hook_has_no_lease_and_guarded_reentry_requires_admission(
        self,
    ):
        _, command = self.guarded_fixture(commit=True)
        hooks = self.directory / "no-hooks"
        hooks.mkdir()
        ready = self.directory / "detached-ready.json"
        release = self.directory / "release-detached"
        result_path = self.directory / "detached-result.json"
        marker = self.directory / "unrelated-detached-marker"
        child = self.directory / "detached-child.py"
        library = self.installed / "skills/commit-capture/scripts/lib/capture-owner.py"
        child.write_text(
            "import json, os, runpy, signal, subprocess, time\n"
            "from pathlib import Path\n"
            "signal.alarm(12)\n"
            f"owner = runpy.run_path({str(library)!r})\n"
            "original = os.environ.get('OBSIDIAN_CAPTURE_LEASE_FD')\n"
            "valid = []\n"
            "for entry in Path('/dev/fd').iterdir():\n"
            "    if entry.name.isdecimal():\n"
            "        os.environ['OBSIDIAN_CAPTURE_LEASE_FD'] = entry.name\n"
            "        if owner['lease_valid']():\n"
            "            valid.append(int(entry.name))\n"
            "if original is None:\n"
            "    os.environ.pop('OBSIDIAN_CAPTURE_LEASE_FD', None)\n"
            "else:\n"
            "    os.environ['OBSIDIAN_CAPTURE_LEASE_FD'] = original\n"
            f"ready = Path({str(ready)!r})\n"
            "temporary = ready.with_suffix('.tmp')\n"
            "temporary.write_text(json.dumps(dict(pid=os.getpid(), pgid=os.getpgrp(), valid_lease_fds=valid)))\n"
            "temporary.replace(ready)\n"
            f"release = Path({str(release)!r})\n"
            "while not release.exists():\n"
            "    time.sleep(0.02)\n"
            f"Path({str(marker)!r}).touch()\n"
            f"result = subprocess.run({shlex.split(command)!r}, capture_output=True, text=True, timeout=5)\n"
            f"output = Path({str(result_path)!r})\n"
            "temporary = output.with_suffix('.tmp')\n"
            "temporary.write_text(json.dumps(dict(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)))\n"
            "temporary.replace(output)\n"
            "while True:\n"
            "    time.sleep(0.1)\n"
        )
        launcher = (
            "import subprocess, time\nfrom pathlib import Path\n"
            f"subprocess.Popen({[sys.executable, '-I', '-B', str(child)]!r}, "
            "start_new_session=True, close_fds=False, stdin=subprocess.DEVNULL, "
            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
            f"ready = Path({str(ready)!r})\n"
            "deadline = time.monotonic() + 5\n"
            "while not ready.exists() and time.monotonic() < deadline:\n"
            "    time.sleep(0.02)\n"
            "raise SystemExit(0 if ready.exists() else 1)\n"
        )
        hook = hooks / "pre-commit"
        hook.write_text(
            "#!/bin/sh\n"
            + shlex.join([sys.executable, "-I", "-B", "-c", launcher])
            + "\n"
        )
        hook.chmod(0o700)
        pid = None
        try:
            result = self.run_emitted(command)
            self.assertEqual(result.returncode, 0, result.stderr)
            information = json.loads(ready.read_bytes())
            pid = information["pid"]
            self.assertGreater(pid, 1)
            self.assertNotIn(pid, (os.getpid(), os.getpgrp()))
            self.assertEqual(information["pgid"], pid)
            self.assertEqual(information["valid_lease_fds"], [])
            before_profile = self.snapshot(self.profile)
            before_owner = self.snapshot(self.state)
            with (self.state / "capture-ownership/admission.lock").open("r+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                release.touch()
                deadline = time.monotonic() + 6
                while not result_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(result_path.exists())
                response = json.loads(result_path.read_bytes())
                self.assertTrue(marker.exists())
                self.assertEqual(response["returncode"], 2, response)
                self.assertIn("busy", response["stderr"])
                self.assertEqual(self.snapshot(self.profile), before_profile)
                self.assertEqual(self.snapshot(self.state), before_owner)
        finally:
            if pid is None and ready.exists():
                pid = json.loads(ready.read_bytes())["pid"]
            if pid is not None:
                process = subprocess.run(
                    ["ps", "-ww", "-p", str(pid), "-o", "command="],
                    capture_output=True,
                    text=True,
                    timeout=2,
                )
                if str(child) in shlex.split(process.stdout):
                    try:
                        if os.getpgid(pid) == pid and pid != os.getpgrp():
                            os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def assert_guard_output_backpressure(self, kind):
        stream_case = kind in ("stdout", "stderr", "deadline")
        runtime, command = self.guarded_fixture(
            commit=stream_case,
            commit_command="git commit -F message.txt"
            if kind != "stderr"
            else "git commit -m fixture",
        )
        started = self.directory / "backpressure-group"
        unpublished = self.directory / "backpressure-group.tmp"
        marker = self.directory / "backpressure-continued"
        release = self.directory / "release-backpressure"
        if stream_case:
            (self.project / "message.txt").write_text("x" * 200000 + "\n")
            hooks = self.directory / "no-hooks"
            hooks.mkdir()
            hook = hooks / "pre-commit"
            hook.write_text(
                "#!/bin/sh\n/bin/ps -o pgid= -p $$ > "
                + shlex.quote(str(unpublished))
                + "\n/bin/mv "
                + shlex.quote(str(unpublished))
                + " "
                + shlex.quote(str(started))
                + "\n(while [ ! -e "
                + shlex.quote(str(release))
                + " ]; do /bin/sleep 0.02; done\n/usr/bin/touch "
                + shlex.quote(str(marker))
                + "\n) </dev/null >/dev/null 2>&1 &\n/usr/bin/head -c 200000 /dev/zero "
                + (">&2" if kind == "stderr" else "")
                + "\nexit 0\n"
            )
            hook.chmod(0o700)
            self.assertTrue(
                os.access(hook, os.X_OK),
                "backpressure fixture requires executable temporary storage",
            )
        elif kind == "json":
            words = shlex.split(command)
            boundary = words.index("--") + 1
            command = shlex.join(
                [*words[:boundary], "status", *words[boundary + 1 : -4]]
            )
        elif kind == "diagnostic":
            (runtime / "bin/obsidian-mcp-native").write_text(
                "raise RuntimeError('tamper')\n"
            )
        elif kind in ("parser-error", "parser-help"):
            words = shlex.split(command)
            command = shlex.join(
                words[: words.index("--authorization")]
                + (["--help"] if kind == "parser-help" else [])
            )
        reader, writer = os.pipe()
        os.write(writer, b"x")
        original_flags = fcntl.fcntl(writer, fcntl.F_GETFL)
        if not stream_case:
            try:
                os.set_blocking(writer, False)
                while True:
                    try:
                        os.write(writer, b"x" * 8192)
                    except BlockingIOError:
                        break
            finally:
                fcntl.fcntl(writer, fcntl.F_SETFL, original_flags)
        blocked_stderr = kind in ("stderr", "diagnostic", "parser-error")
        process = subprocess.Popen(
            shlex.split(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL if blocked_stderr else writer,
            stderr=writer if blocked_stderr else subprocess.DEVNULL,
            env=self.env,
            cwd=self.project,
            start_new_session=True,
        )
        group = None
        try:
            if stream_case:
                deadline = time.monotonic() + 10
                while not started.exists() and time.monotonic() < deadline:
                    self.assertIsNone(process.poll())
                    time.sleep(0.02)
                self.assertTrue(started.exists())
                group = int(started.read_text().strip())
                self.assertNotIn(group, (os.getpgrp(), process.pid))
                available = array.array("i", [0])
                while time.monotonic() < deadline:
                    fcntl.ioctl(reader, termios.FIONREAD, available, True)
                    self.assertIsNone(process.poll())
                    if available[0] > 1 and not select.select([], [writer], [], 0)[1]:
                        break
                    time.sleep(0.02)
                self.assertGreater(available[0], 1)
                self.assertFalse(select.select([], [writer], [], 0)[1])
            if kind in ("stdout", "stderr"):
                process.terminate()
                process.wait(timeout=3)
                self.assertEqual(process.returncode, 143)
            else:
                process.wait(timeout=8)
                self.assertEqual(process.returncode, 0 if kind == "parser-help" else 2)
            with (self.state / "capture-ownership/admission.lock").open("r+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if stream_case:
                    release.touch()
                    time.sleep(0.3)
                    self.assertFalse(marker.exists())
            self.assertEqual(fcntl.fcntl(writer, fcntl.F_GETFL), original_flags)
            self.assertTrue(os.get_blocking(writer))
        finally:
            if group is not None:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            os.close(writer)
            os.close(reader)

    def test_guard_cancels_unread_stdout_without_releasing_live_descendants(self):
        self.assert_guard_output_backpressure("stdout")

    def test_guard_cancels_unread_stderr_without_releasing_live_descendants(self):
        self.assert_guard_output_backpressure("stderr")

    def test_guard_bounds_unread_stream_without_a_signal(self):
        self.assert_guard_output_backpressure("deadline")

    def test_guard_bounds_unread_final_native_response(self):
        self.assert_guard_output_backpressure("native")

    def test_guard_bounds_unread_final_json_response(self):
        self.assert_guard_output_backpressure("json")

    def test_guard_bounds_unread_diagnostics(self):
        self.assert_guard_output_backpressure("diagnostic")

    def test_guard_bounds_unread_parser_error(self):
        self.assert_guard_output_backpressure("parser-error")

    def test_guard_bounds_unread_parser_help(self):
        self.assert_guard_output_backpressure("parser-help")

    def test_guard_sigterm_stops_owned_executor_before_releasing_lease(self):
        _, command = self.guarded_fixture(commit=True)
        hooks = self.directory / "no-hooks"
        hooks.mkdir()
        started = self.directory / "owned-group"
        unpublished = self.directory / "owned-group.tmp"
        marker = self.directory / "orphan-continued"
        hook = hooks / "pre-commit"
        hook.write_text(
            "#!/bin/sh\n/bin/ps -o pgid= -p $$ > "
            + shlex.quote(str(unpublished))
            + "\n/bin/mv "
            + shlex.quote(str(unpublished))
            + " "
            + shlex.quote(str(started))
            + "\n/bin/sleep 2\ntouch "
            + shlex.quote(str(marker))
            + "\n/bin/sleep 8\n"
        )
        hook.chmod(0o700)
        process = subprocess.Popen(
            shlex.split(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            cwd=self.project,
            start_new_session=True,
        )
        group = None
        try:
            deadline = time.monotonic() + 10
            while (
                not started.exists()
                and process.poll() is None
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)
            self.assertTrue(
                started.exists(), "owned native executor did not reach the fixture hook"
            )
            group = int(started.read_text().strip())
            self.assertNotIn(group, (os.getpgrp(), process.pid))
            process.terminate()
            process.wait(timeout=5)
            lock_available = True
            with (self.state / "capture-ownership/admission.lock").open("r+") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    lock_available = False
            time.sleep(2.2)
            self.assertFalse(
                marker.exists(), "executor continued after its guard was terminated"
            )
            self.assertTrue(
                lock_available, "terminated guard left an executor holding admission"
            )
            self.assertEqual(process.returncode, 143)
            state = json.loads(self.states()[0].read_bytes())
            self.assertTrue(state["snapshots"])
            self.assertEqual(state["commits"], {})
        finally:
            if group is not None:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    def test_guarded_status_takeover_and_snapshot_resolution_guidance(self):
        _, command = self.guarded_fixture(commit=True)
        words = shlex.split(command)
        boundary = words.index("--")
        prefix, native = words[: boundary + 1], words[boundary + 1 :]
        output = self.event("Stop", stop_hook_active=True)
        self.assertIn(
            shlex.join([*prefix, "resolve-snapshot"]), output["systemMessage"]
        )
        self.event(
            "UserPromptSubmit",
            session_id="competing-session",
            turn_id="competing-turn",
            prompt="Competing fixture work",
        )
        output = self.event(
            "PreToolUse",
            session_id="competing-session",
            turn_id="competing-turn",
            tool_name="Bash",
            tool_use_id="competing-commit",
            tool_input={"command": "git commit -m competing"},
        )
        specific = output["hookSpecificOutput"]
        self.assertIn(specific.get("permissionDecision"), (None, "deny"))
        self.assertNotIn("updatedInput", specific)
        text = specific.get("additionalContext", specific.get("permissionDecisionReason"))
        self.assertIsInstance(text, str)
        status = text.split("Inspect it with ", 1)[1].split(", then rescue", 1)[0]
        takeover = text.split("then rescue interrupted ownership with ", 1)[
            1
        ].split("\n", 1)[0].removesuffix(".")
        inspected = self.run_emitted(status)
        self.assertEqual(inspected.returncode, 0, inspected.stderr)
        self.assertTrue(json.loads(inspected.stdout)["snapshots"])
        for snapshot in json.loads(inspected.stdout)["snapshots"].values():
            self.assertIn("codex-execute", snapshot["wrapped"])
        resolved = self.run_emitted(
            shlex.join(
                [
                    *prefix,
                    "resolve-snapshot",
                    *native[1:],
                    "--verification",
                    "command-stopped-and-history-inspected",
                ]
            )
        )
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        self.assertEqual(json.loads(resolved.stdout)["status"], "not_captured")
        self.event(
            "PreToolUse",
            tool_name="Bash",
            tool_use_id="guard-commit-again",
            tool_input={"command": "git commit -m fixture"},
        )
        recovered = self.run_emitted(takeover)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(json.loads(recovered.stdout)["status"], "recovered")
        original = next(
            path
            for path in self.states()
            if path.stem == hashlib.sha256(b"native-session").hexdigest()
        )
        state = json.loads(original.read_bytes())
        self.assertEqual(state["commits"], {})
        self.assertEqual(state["snapshots"], {})
        self.assertTrue(state["snapshot_resolutions"])

    def test_guard_guidance_rewrite_preserves_quoted_json_and_payload_fields(self):
        _, guarded = self.guarded_fixture()
        words = shlex.split(guarded)
        token = words[words.index("--authorization") + 1]
        native_arguments = words[words.index("--") + 1 :]
        library = self.installed / "skills/commit-capture/scripts/lib/capture-owner.py"
        runtime = runpy.run_path(str(library))
        binding = runtime["codex_decode_authorization"](token)["binding"]
        native = shlex.join(
            [
                binding["python"],
                str(Path(binding["bundle"]) / "bin/obsidian-mcp-native"),
                *native_arguments,
            ]
        )
        frozen = {
            "body": "acknowledge explicitly with "
            + native
            + " (or user_requested_no_capture)",
            "wrapped": native,
            "reason": native,
        }
        opaque = json.dumps(frozen, ensure_ascii=False, separators=(",", ":"))
        output = {
            "hookSpecificOutput": {
                "additionalContext": opaque
                + "\nOnly for no meaningful work, acknowledge explicitly with "
                + native
                + " (or user_requested_no_capture)."
            },
            "arguments": frozen,
            "body": opaque,
        }
        rewritten = runtime["codex_guard_output"](output, token, binding)
        text = rewritten["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(text.split("\n", 1)[0], opaque)
        self.assertIn("codex-execute", text.split("\n", 1)[1])
        self.assertEqual(rewritten["arguments"], frozen)
        self.assertEqual(rewritten["body"], opaque)

    def test_guard_bounds_output_without_discarding_pending_state(self):
        _, command = self.guarded_fixture(commit=True)
        hooks = self.directory / "no-hooks"
        hooks.mkdir()
        hook = hooks / "pre-commit"
        hook.write_text(
            "#!/bin/sh\n/usr/bin/head -c 1100000 /dev/zero\n/bin/sleep 10\n"
        )
        hook.chmod(0o700)
        result = self.run_emitted(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output exceeds", result.stderr)
        state = json.loads(self.states()[0].read_bytes())
        self.assertTrue(state["snapshots"])
        self.assertEqual(state["commits"], {})
        with (self.state / "capture-ownership/admission.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_guard_rechecks_physical_home_ambiguity(self):
        _, command = self.guarded_fixture()
        alias = self.case_alias(self.home)
        value = json.loads(self.record_path().read_bytes())
        value["codex_home"] = str(alias)
        duplicate = self.record_path().with_name(
            hashlib.sha256(str(alias).encode()).hexdigest() + ".json"
        )
        duplicate.write_text(json.dumps(value))
        duplicate.chmod(0o600)
        before = self.snapshot(self.profile)
        result = self.run_emitted(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple", result.stderr)
        self.assertEqual(self.snapshot(self.profile), before)

    def test_guard_native_execution_ignores_pythonpath(self):
        _, command = self.guarded_fixture()
        marker = self.directory / "pythonpath-executed"
        modules = self.directory / "untrusted-modules"
        modules.mkdir()
        (modules / "sitecustomize.py").write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
        )
        self.env["PYTHONPATH"] = str(modules)
        result = self.run_emitted(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())

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

    def test_both_exact_duplicate_home_records_close_all_admission(self):
        alias = self.case_alias(self.home)
        self.activate()
        second_profile = self.directory / "duplicate-profile"
        self.native(
            "attach",
            "--host",
            "codex",
            "--scope",
            "user",
            "--home",
            str(second_profile),
            "--folder",
            "Sessions",
            "--release-sha256",
            self.digest,
        )
        original = json.loads(self.record_path().read_bytes())
        binding = dict(original["retained_profiles"][0], profile=str(second_profile))
        duplicate = dict(
            original, **binding, codex_home=str(alias), retained_profiles=[binding]
        )
        duplicate_path = self.record_path().with_name(
            hashlib.sha256(str(alias).encode()).hexdigest() + ".json"
        )
        duplicate_path.write_text(json.dumps(duplicate))
        duplicate_path.chmod(0o600)
        before = {
            profile: self.snapshot(profile)
            for profile in (self.profile, second_profile)
        }
        for spelling in (self.home, alias):
            self.env["CODEX_HOME"] = str(spelling)
            with self.subTest(spelling=spelling.name, entry="status"):
                result = self.cli("codex-status")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("multiple", result.stderr)
            for tool in (
                "mcp__obsidian_write__obsidian_keeper_save",
                "mcp__obsidian_write__obsidian_daily_append",
            ):
                with self.subTest(spelling=spelling.name, entry=tool):
                    output = self.installed_hook(
                        "PreToolUse",
                        json.dumps(
                            dict(
                                hook_event_name="PreToolUse",
                                session_id="duplicate-session",
                                turn_id="duplicate-turn",
                                cwd=str(self.project),
                                tool_name=tool,
                            )
                        ),
                        tool=tool,
                    )
                    self.assertEqual(
                        output.get("hookSpecificOutput", {}).get("permissionDecision"),
                        "deny",
                    )
                    self.assertIn("multiple", json.dumps(output))
            for event in ("UserPromptSubmit", "Stop"):
                with self.subTest(spelling=spelling.name, entry=event):
                    output = self.installed_hook(
                        event,
                        json.dumps(
                            dict(
                                hook_event_name=event,
                                session_id="duplicate-session",
                                turn_id="duplicate-turn",
                                cwd=str(self.project),
                                prompt="Do not enroll ambiguous writers",
                            )
                        ),
                    )
                    self.assertIn("multiple", json.dumps(output))
                    self.assertNotIn("decision", output)
            with self.subTest(spelling=spelling.name, entry="legacy"):
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
                self.assertIn("multiple", result.stderr)
            with self.subTest(spelling=spelling.name, entry="no capture evidence"):
                self.assertEqual(
                    {profile: self.snapshot(profile) for profile in before}, before
                )

    def test_exact_home_lookup_also_validates_corrupt_inventory(self):
        self.activate()
        corrupt = self.record_path().with_name("invalid.json")
        corrupt.write_text("{}")
        corrupt.chmod(0o600)
        result = self.cli("codex-status")
        self.assertNotEqual(result.returncode, 0)
        output = self.installed_hook(
            "PreToolUse",
            json.dumps(
                dict(
                    hook_event_name="PreToolUse",
                    tool_name="mcp__obsidian_write__obsidian_keeper_save",
                )
            ),
            tool="mcp__obsidian_write__obsidian_keeper_save",
        )
        self.assertEqual(
            output.get("hookSpecificOutput", {}).get("permissionDecision"), "deny"
        )
        self.assertIn("inventory", json.dumps(output))

    def test_hook_rechecks_duplicate_identity_under_admission_lock(self):
        alias = self.case_alias(self.home)
        self.activate()
        record = json.loads(self.record_path().read_bytes())
        record["codex_home"] = str(alias)
        saved = self.directory / "concurrently-published.json"
        saved.write_text(json.dumps(record))
        saved.chmod(0o600)
        target = self.record_path().with_name(
            hashlib.sha256(str(alias).encode()).hexdigest() + ".json"
        )
        before = self.snapshot(self.profile)
        program = """
from contextlib import contextmanager
import runpy, shutil, sys
library, saved, target = sys.argv[1:]
main = runpy.run_path(library)['codex_main']
namespace = main.__globals__
admission = namespace['admission']
@contextmanager
def published_before_admission(exclusive=False):
    with admission(exclusive=exclusive) as descriptor:
        shutil.copy2(saved, target)
        yield descriptor
namespace['admission'] = published_before_admission
sys.argv = [library, 'codex-route', '--event', 'PreToolUse', '--tool-class', 'owned-write']
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
                str(target),
            ],
            input=json.dumps(
                dict(
                    hook_event_name="PreToolUse",
                    tool_name="mcp__obsidian_write__obsidian_keeper_save",
                    cwd=str(self.project),
                )
            ),
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("multiple", json.dumps(output))
        self.assertEqual(self.snapshot(self.profile), before)

    def test_recorded_missing_home_preserves_textual_identity(self):
        missing = self.directory / "missing-home"
        self.home = missing
        self.activate()
        self.assertFalse(missing.exists())
        result = self.cli("codex-status", "--codex-home", str(missing))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "configured")
        self.assertEqual(json.loads(result.stdout)["codex_home"], str(missing))
        result = self.cli(
            "codex-status", "--codex-home", str(missing.with_name(missing.name.upper()))
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "dormant")

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
