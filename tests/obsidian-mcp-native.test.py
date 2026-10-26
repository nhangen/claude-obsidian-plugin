#!/usr/bin/env python3
from contextlib import contextmanager
import hashlib
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


class NativeCaptureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name).resolve()
        cls.bundle = cls.root / "client"
        subprocess.run(
            [
                "python3",
                str(ROOT / "scripts/pack-obsidian-mcp-client.py"),
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
        self.directory = Path(self.temp.name)
        self.project = self.directory / "project"
        self.project.mkdir()
        self.home = self.directory / "codex"
        self.environment = dict(
            os.environ,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="Fixture",
            GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Fixture",
            GIT_COMMITTER_EMAIL="fixture@example.invalid",
        )
        self.git("init", "-b", "native-fixture")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.project), *args],
            env=self.environment,
            text=True,
            capture_output=True,
            check=True,
        )

    def cli(self, *args, payload=None):
        return subprocess.run(
            [str(self.bundle / "bin/obsidian-mcp-native"), *args],
            input=json.dumps(payload) if payload is not None else "",
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def configure(self, **extra):
        result = self.cli(
            "create",
            "--home",
            str(self.home),
            "--project",
            str(self.project),
            "--folder",
            "Projects/Development/fixture/native",
            "--release-sha256",
            extra.get("digest", self.digest),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def event(self, name, **extra):
        return dict(
            session_id="session-1",
            turn_id="turn-1",
            cwd=str(self.project),
            hook_event_name=name,
            **extra,
        )

    def session_key(self, name):
        return hashlib.sha256(name.encode()).hexdigest()

    def state_paths(self):
        return [
            path
            for path in (self.home / "capture-state").glob("*.json")
            if path.name != "active.json"
        ]

    def hook(self, name, **extra):
        if extra.get("tool_name", "").startswith("mcp__"):
            extra.setdefault("tool_use_id", "fixture-mcp-call")
        result = self.cli(
            "hook", "--home", str(self.home), payload=self.event(name, **extra)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout or "{}")

    def pending_commit(self):
        args = dict(
            tool_name="Bash",
            tool_use_id="commit-call",
            tool_input={"command": "git commit -m fixture"},
        )
        rewritten = self.hook("PreToolUse", **args)
        (self.project / "file.txt").write_text("fixture\n")
        self.git("add", "file.txt")
        executed = self.execute_rewritten(rewritten)
        self.assertEqual(executed.returncode, 0, executed.stderr)
        self.hook("PostToolUse", **args, tool_response=executed.stdout)
        path = next(iter(self.state_paths()))
        state = json.loads(path.read_text())
        return path, state, next(iter(state["commits"]))

    def execute_rewritten(self, rewritten):
        self.assertEqual(rewritten["hookSpecificOutput"]["permissionDecision"], "allow")
        return subprocess.run(
            shlex.split(rewritten["hookSpecificOutput"]["updatedInput"]["command"]),
            env=self.environment,
            cwd=self.project,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def prepare(self, path, commit, payload=None):
        return self.cli(
            "prepare",
            "--home",
            str(self.home),
            "--session",
            path.stem,
            "--commit",
            commit,
            payload=payload
            or {
                "context": [
                    "Implemented fixture change",
                    "Verified production entry point",
                ]
            },
        )

    def append_event(self, arguments, status="committed", call="append-1"):
        target = arguments["target_path"]
        partial = status == "partial"
        receipt = dict(
            status=status,
            request_id="fixture-request",
            idempotency_key=arguments["idempotency_key"],
            path=target,
            affected_paths=[target],
            warnings=[],
            recovery={
                "required": partial,
                "action": "inspect fixture" if partial else "",
            },
            error_code="PARTIAL" if partial else None,
            retryable=partial,
        )
        event = dict(
            tool_name="mcp__obsidian_write__obsidian_daily_append",
            tool_use_id=call,
            tool_input=arguments,
        )
        before = self.hook("PreToolUse", **event)
        self.assertNotIn("permissionDecision", before.get("hookSpecificOutput", {}))
        return self.hook(
            "PostToolUse",
            **event,
            tool_response={"structuredContent": receipt, "isError": partial},
        )

    def test_native_commit_preparation_receipt_replay_and_changed_payload(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, state, commit = self.pending_commit()
        prepared = self.prepare(path, commit)
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        arguments = json.loads(prepared.stdout)["arguments"]
        pending = state["commits"][commit]
        self.assertEqual(arguments["skip_if_hash"], pending["event"]["commit"])
        self.assertEqual(
            arguments["target_path"],
            "Projects/Development/local/project/" + pending["metadata"]["date"] + ".md",
        )
        self.append_event(arguments)
        self.assertEqual(
            json.loads(self.prepare(path, commit).stdout)["status"], "skipped"
        )
        changed = self.prepare(path, commit, {"context": ["Different payload"]})
        self.assertEqual(changed.returncode, 64)
        self.assertIn("COMMIT_PAYLOAD_CHANGED", changed.stderr)

    def test_run_rejects_config_project_and_profile_overrides(self):
        self.configure()
        for option in (
            "-cfeatures.hooks=false",
            "-C/private/tmp",
            "-pother",
            "--config=features.hooks=false",
            "--cd=/private/tmp",
            "--profile=other",
        ):
            with self.subTest(option=option):
                result = self.cli("run", "--home", str(self.home), option)
                self.assertEqual(result.returncode, 64)
                self.assertIn("PROFILE_OVERRIDE_REFUSED", result.stderr)

    def test_run_isolates_profile_home_xdg_cwd_and_forwards_arguments(self):
        self.configure()
        fake_bin = self.directory / "bin"
        fake_bin.mkdir()
        output = self.directory / "codex-observed.json"
        codex = fake_bin / "codex"
        codex.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['NATIVE_FIXTURE_OUTPUT']).write_text(json.dumps({"
            "'cwd': os.getcwd(), 'argv': sys.argv[1:], 'environment': {"
            "key: os.environ[key] for key in ('HOME', 'CODEX_HOME', "
            "'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME')}}))\n"
        )
        codex.chmod(0o700)
        self.environment.update(
            PATH=str(fake_bin) + os.pathsep + self.environment["PATH"],
            NATIVE_FIXTURE_OUTPUT=str(output),
        )
        result = self.cli(
            "run", "--home", str(self.home), "exec", "--json", "fixture prompt"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        observed = json.loads(output.read_text())
        self.assertEqual(observed["cwd"], str(self.project))
        self.assertEqual(observed["argv"], ["exec", "--json", "fixture prompt"])
        runtime = self.home / "runtime-home"
        self.assertEqual(
            observed["environment"],
            {
                "HOME": str(runtime),
                "CODEX_HOME": str(self.home),
                "XDG_CONFIG_HOME": str(runtime / ".config"),
                "XDG_DATA_HOME": str(runtime / ".local/share"),
                "XDG_STATE_HOME": str(runtime / ".local/state"),
                "XDG_CACHE_HOME": str(runtime / ".cache"),
            },
        )

    def test_native_trust_records_are_allowed_but_capture_config_drift_is_rejected(
        self,
    ):
        self.configure()
        config = self.home / "config.toml"
        original = config.read_text()
        config.write_text(
            original
            + '\n[tui]\nscreen_reader_detection_done = true\n[projects."/fixture"]\ntrust_level = "trusted"\n[hooks.state."fixture-hook"]\ntrusted_hash = "sha256:fixture"\n'
        )
        self.hook("UserPromptSubmit", prompt="work")
        config.write_text(config.read_text().replace("hooks = true", "hooks = false"))
        result = self.cli("status", "--home", str(self.home))
        self.assertEqual(result.returncode, 64)
        self.assertIn("PROFILE_DRIFT", result.stderr)

    def test_partial_commit_outcome_stays_visible_and_blocks_automatic_retry(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, _state, commit = self.pending_commit()
        arguments = json.loads(self.prepare(path, commit).stdout)["arguments"]
        self.append_event(arguments, "partial")
        pending = json.loads(path.read_text())["commits"][commit]
        self.assertEqual(pending["status"], "pending")
        self.assertTrue(pending["recovery"]["recovery"]["required"])
        denied = self.hook(
            "PreToolUse",
            tool_name="mcp__obsidian_write__obsidian_daily_append",
            tool_use_id="unreviewed",
            tool_input=arguments,
        )
        self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(self.prepare(path, commit).returncode, 64)

    def test_reprepare_preserves_full_arguments_across_branch_identity_changes(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, _state, commit = self.pending_commit()
        before = json.loads(self.prepare(path, commit).stdout)
        self.git("branch", "-m", "renamed-fixture")
        self.git(
            "remote",
            "add",
            "origin",
            "git@github.com:different-owner/different-project.git",
        )
        after = json.loads(self.prepare(path, commit).stdout)
        self.assertEqual(before, after)

    def test_two_reflog_transitions_are_not_attributed_to_one_tool_call(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        args = dict(
            tool_name="Bash",
            tool_use_id="two-commits",
            tool_input={"command": "git commit -m fixture"},
        )
        rewritten = self.hook("PreToolUse", **args)
        for number in range(2):
            (self.project / "file.txt").write_text(str(number))
            self.git("add", "file.txt")
            if number == 0:
                self.git("commit", "-m", "fixture")
        executed = self.execute_rewritten(rewritten)
        self.assertEqual(executed.returncode, 64)
        result = self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=self.event("PostToolUse", **args, tool_response={"exit_code": 0}),
        )
        self.assertEqual(result.returncode, 0)
        state = json.loads(
            next(iter(self.state_paths())).read_text()
        )
        self.assertEqual(state["commits"], {})

    def test_new_prompt_cannot_discard_unresolved_previous_turn(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        result = self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=dict(
                self.event("UserPromptSubmit", prompt="next"), turn_id="turn-2"
            ),
        )
        self.assertEqual(result.returncode, 64)
        state = json.loads(
            next(iter(self.state_paths())).read_text()
        )
        self.assertEqual(state["turn"], "turn-1")

    def test_save_after_policy_skip_keeps_inflight_and_partial_work_unresolved(self):
        for outcome in ("inflight", "partial"):
            with self.subTest(outcome=outcome):
                self.home = self.directory / outcome
                self.configure()
                self.hook("UserPromptSubmit", prompt="work")
                path = next(iter(self.state_paths()))
                state = json.loads(path.read_text())
                skipped = self.cli(
                    "skip",
                    "--home",
                    str(self.home),
                    "--session",
                    path.stem,
                    "--turn",
                    "turn-1",
                    "--reason",
                    "no_meaningful_work",
                )
                self.assertEqual(skipped.returncode, 0, skipped.stderr)
                plan = state["session_save"]
                arguments = dict(
                    title=plan["title"],
                    body="Later meaningful work",
                    folder_hint=plan["folder"],
                    session_link_date=plan["date"],
                    idempotency_key=plan["idempotency_key"],
                    resolved=True,
                )
                event = dict(
                    tool_name="mcp__obsidian_write__obsidian_keeper_save",
                    tool_input=arguments,
                    tool_use_id="later-save",
                )
                self.assertEqual(self.hook("PreToolUse", **event), {})
                if outcome == "partial":
                    self.hook(
                        "PostToolUse",
                        **event,
                        tool_response={
                            "structuredContent": {
                                "status": "partial",
                                "error_code": "PARTIAL",
                            }
                        },
                    )
                self.assertEqual(
                    self.hook("Stop", stop_hook_active=False)["decision"], "block"
                )
                next_turn = self.cli(
                    "hook",
                    "--home",
                    str(self.home),
                    payload=dict(
                        self.event("UserPromptSubmit", prompt="next"), turn_id="turn-2"
                    ),
                )
                self.assertEqual(next_turn.returncode, 64)
                self.assertIn("PREVIOUS_CAPTURE_UNRESOLVED", next_turn.stderr)
                remaining = json.loads(path.read_text())
                self.assertEqual(remaining["turn"], "turn-1")
                self.assertEqual(remaining["session_request"], arguments)
                self.assertEqual(remaining["disposition"], "pending")
                self.assertNotIn("skip_reason", remaining)

    def test_profile_trust_ownership_and_rollback(self):
        self.configure()
        config = (self.home / "config.toml").read_text()
        self.assertIn('default_tools_approval_mode = "auto"', config)
        self.assertNotIn("plugin", config)
        hooks = json.loads((self.home / "hooks.json").read_text())["hooks"]
        for event in ("PreToolUse", "PostToolUse"):
            for tool in ("obsidian_keeper_save", "obsidian_daily_append"):
                self.assertIsNotNone(
                    re.fullmatch(
                        hooks[event][0]["matcher"], "mcp__obsidian_write__" + tool
                    )
                )
        self.assertEqual(
            self.cli(
                "create",
                "--home",
                str(self.home),
                "--project",
                str(self.project),
                "--folder",
                "Projects/Development/fixture/native",
                "--release-sha256",
                self.digest,
            ).returncode,
            64,
        )
        (self.home / "auth.json").write_text("fixture credentials")
        result = self.cli("disable", "--home", str(self.home))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / "hooks.json").exists())
        self.assertEqual((self.home / "auth.json").read_text(), "fixture credentials")
        self.assertEqual(
            self.cli(
                "hook",
                "--home",
                str(self.home),
                payload=self.event("Stop", stop_hook_active=False),
            ).returncode,
            64,
        )

    def test_wrong_digest_and_inherited_capture_are_rejected_without_profile(self):
        result = self.cli(
            "create",
            "--home",
            str(self.home),
            "--project",
            str(self.project),
            "--folder",
            "Projects/Development/fixture/native",
            "--release-sha256",
            "0" * 64,
        )
        self.assertEqual(result.returncode, 64)
        self.assertFalse(self.home.exists())
        (self.project / ".codex").mkdir()
        result = self.cli(
            "create",
            "--home",
            str(self.home),
            "--project",
            str(self.project),
            "--folder",
            "Projects/Development/fixture/native",
            "--release-sha256",
            self.digest,
        )
        self.assertEqual(result.returncode, 64)
        self.assertFalse(self.home.exists())

    def test_managed_release_supports_native_create_and_verifies_installed_trust(self):
        prefix = self.directory / "managed-client"
        installed = subprocess.run(
            [
                str(self.bundle / "bin/obsidian-mcp-client-install"),
                "--prefix",
                str(prefix),
                "--bundle",
                str(self.bundle),
                "--release-sha256",
                self.digest,
            ],
            env=self.environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.bundle = prefix / "current"
        wrong = self.cli(
            "create",
            "--home",
            str(self.home),
            "--project",
            str(self.project),
            "--folder",
            "Projects/fixture",
            "--release-sha256",
            "0" * 64,
        )
        self.assertEqual(wrong.returncode, 64)
        self.assertIn("BUNDLE_UNTRUSTED", wrong.stderr)
        self.assertFalse(self.home.exists())
        self.configure()
        self.hook("UserPromptSubmit", prompt="installed capture")
        installed_readme = self.bundle / "README.md"
        installed_readme.chmod(0o600)
        installed_readme.write_text(installed_readme.read_text() + "tampered")
        rejected = self.cli("status", "--home", str(self.home))
        self.assertEqual(rejected.returncode, 64)
        self.assertIn("BUNDLE_UNTRUSTED", rejected.stderr)

    def test_profile_drift_blocks_hook_and_disable(self):
        self.configure()
        hooks = self.home / "hooks.json"
        hooks.write_text(hooks.read_text() + " ")
        self.assertEqual(self.cli("disable", "--home", str(self.home)).returncode, 64)
        self.assertTrue(hooks.exists())
        self.assertEqual(
            self.cli(
                "hook",
                "--home",
                str(self.home),
                payload=self.event("UserPromptSubmit", prompt="work"),
            ).returncode,
            64,
        )

    def test_stop_requires_receipt_and_never_promotes_attempt_to_success(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="Review a design")
        first = self.hook("Stop", stop_hook_active=False)
        self.assertEqual(first["decision"], "block")
        second = self.hook("Stop", stop_hook_active=True)
        self.assertIn("unresolved", second["systemMessage"])
        self.assertNotIn("decision", second)

    def test_session_receipt_requires_matching_key_path_and_backlinks(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="Review a design")
        state = json.loads(
            next(iter(self.state_paths())).read_text()
        )
        expected = state["session_save"]
        receipt = dict(
            status="committed",
            request_id="fixture-request",
            path=expected["path"],
            idempotency_key=expected["idempotency_key"],
            affected_paths=[expected["path"], expected["index"], expected["daily"]],
            recovery={"required": False, "action": ""},
            error_code=None,
            retryable=False,
            warnings=[],
        )
        args = dict(
            title=expected["title"],
            body="Meaningful planning",
            resolved=True,
            folder_hint=expected["folder"],
            session_link_date=expected["date"],
            idempotency_key=expected["idempotency_key"],
        )
        self.hook(
            "PreToolUse",
            tool_name="mcp__obsidian_write__obsidian_keeper_save",
            tool_input=args,
        )
        for patch in (
            {"idempotency_key": "wrong"},
            {"path": "Projects/wrong-note.md"},
            {"affected_paths": [expected["path"]]},
            {"recovery": {"required": True}},
            {"status": "conflict"},
        ):
            self.hook(
                "PostToolUse",
                tool_name="mcp__obsidian_write__obsidian_keeper_save",
                tool_input=args,
                tool_response={"structuredContent": dict(receipt, **patch)},
            )
            self.assertIn(
                "unresolved", self.hook("Stop", stop_hook_active=True)["systemMessage"]
            )
        self.hook(
            "PostToolUse",
            tool_name="mcp__obsidian_write__obsidian_keeper_save",
            tool_input=args,
            tool_response={"structuredContent": receipt, "isError": False},
        )
        self.assertEqual(self.hook("Stop", stop_hook_active=False), {})
        self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=dict(
                self.event("UserPromptSubmit", prompt="More work"), turn_id="turn-2"
            ),
        )
        self.assertEqual(self.hook("Stop", stop_hook_active=False)["decision"], "block")

    def test_policy_skip_is_explicit_and_turn_bound(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="ok")
        state_file = next(iter(self.state_paths()))
        state = json.loads(state_file.read_text())
        key = state_file.stem
        wrong = self.cli(
            "skip",
            "--home",
            str(self.home),
            "--session",
            key,
            "--turn",
            "wrong",
            "--reason",
            "no_meaningful_work",
        )
        self.assertEqual(wrong.returncode, 64)
        result = self.cli(
            "skip",
            "--home",
            str(self.home),
            "--session",
            key,
            "--turn",
            state["turn"],
            "--reason",
            "no_meaningful_work",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(state_file.read_text())["disposition"], "skipped_by_policy"
        )
        self.assertEqual(self.hook("Stop", stop_hook_active=False), {})

    def test_real_git_event_requires_matching_snapshot_and_single_commit_transition(
        self,
    ):
        self.configure()
        self.hook("UserPromptSubmit", prompt="Implement a change")
        command = shlex.join(
            ["git", "-C", str(self.project), "commit", "-m", "fixture commit"]
        )
        args = dict(
            tool_name="Bash", tool_use_id="commit-1", tool_input={"command": command}
        )
        rewritten = self.hook("PreToolUse", **args)
        (self.project / "file.txt").write_text("first\n")
        self.git("add", "file.txt")
        executed = self.execute_rewritten(rewritten)
        self.assertEqual(executed.returncode, 0, executed.stderr)
        result = self.hook("PostToolUse", **args, tool_response=executed.stdout)
        context = result["hookSpecificOutput"]["additionalContext"]
        self.assertIn("--commit", context)
        self.assertNotIn("captured successfully", context)
        state = json.loads(
            next(iter(self.state_paths())).read_text()
        )
        self.assertEqual(len(state["commits"]), 1)
        pending = next(iter(state["commits"].values()))
        self.assertEqual(
            pending["event"]["commit"], self.git("rev-parse", "HEAD").stdout.strip()
        )
        self.assertEqual(pending["status"], "pending")
        replay = self.execute_rewritten(rewritten)
        self.assertEqual(replay.returncode, 64)
        self.hook("PostToolUse", **args, tool_response={"exit_code": 0})
        self.assertEqual(
            len(
                json.loads(
                    next(iter(self.state_paths())).read_text()
                )["commits"]
            ),
            1,
        )

    def test_executor_failure_and_interrupted_execution_cannot_promote_raw_output(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        args = dict(
            tool_name="Bash",
            tool_use_id="no-changes",
            tool_input={"command": "git commit -m fixture"},
        )
        rewritten = self.hook("PreToolUse", **args)
        failed = self.execute_rewritten(rewritten)
        self.assertNotEqual(failed.returncode, 0)
        self.hook("PostToolUse", **args, tool_response="Process exited with code 0")
        path = next(iter(self.state_paths()))
        self.assertEqual(json.loads(path.read_text())["commits"], {})
        rewritten = self.hook("PreToolUse", **dict(args, tool_use_id="interrupted"))
        state = json.loads(path.read_text())
        snapshot = next(iter(state["snapshots"].values()))
        snapshot["execution_started"] = True
        path.write_text(json.dumps(state))
        refused = self.execute_rewritten(rewritten)
        self.assertEqual(refused.returncode, 64)
        self.assertIn("COMMIT_EXECUTION_UNRESOLVED", refused.stderr)
        result = self.hook(
            "PostToolUse",
            **dict(args, tool_use_id="interrupted"),
            tool_response="Process exited with code 0",
        )
        self.assertIn(
            "outcome unavailable", result["hookSpecificOutput"]["additionalContext"]
        )
        self.assertTrue(json.loads(path.read_text())["snapshots"])

    def test_hooks_and_executor_pin_the_creator_python_when_shell_path_differs(self):
        self.configure()
        bad_bin = self.directory / "bin"
        bad_bin.mkdir()
        python = bad_bin / "python3"
        python.write_text("#!/bin/sh\nexit 77\n")
        python.chmod(0o755)
        self.environment["PATH"] = str(bad_bin) + os.pathsep + os.environ["PATH"]
        hooks = json.loads((self.home / "hooks.json").read_text())["hooks"]
        started = subprocess.run(
            shlex.split(hooks["UserPromptSubmit"][0]["hooks"][0]["command"]),
            input=json.dumps(self.event("UserPromptSubmit", prompt="work")),
            env=self.environment,
            cwd=self.project,
            text=True,
            capture_output=True,
        )
        self.assertEqual(started.returncode, 0, started.stderr)
        args = dict(
            tool_name="Bash",
            tool_use_id="pinned-python",
            tool_input={"command": "git commit -m fixture"},
        )
        rewritten = json.loads(
            subprocess.check_output(
                shlex.split(hooks["PreToolUse"][0]["hooks"][0]["command"]),
                input=json.dumps(self.event("PreToolUse", **args)),
                env=self.environment,
                cwd=self.project,
                text=True,
            )
        )
        (self.project / "file.txt").write_text("fixture")
        self.git("add", "file.txt")
        executed = self.execute_rewritten(rewritten)
        self.assertEqual(executed.returncode, 0, executed.stderr)

    def test_failed_or_ambiguous_shell_never_infers_commit(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        for command in (
            "false && git commit -m nope",
            "git commit -m x; true",
            "git commit -m $(echo x)",
        ):
            output = self.hook(
                "PreToolUse",
                tool_name="Bash",
                tool_use_id="unsupported",
                tool_input={"command": command},
            )
            self.assertIn(
                "unsupported", output["hookSpecificOutput"]["additionalContext"]
            )
        args = dict(
            tool_name="Bash",
            tool_use_id="failed",
            tool_input={"command": "git commit -m x"},
        )
        self.hook("PreToolUse", **args)
        self.hook("PostToolUse", **args, tool_response={"exit_code": 1})
        state = json.loads(
            next(iter(self.state_paths())).read_text()
        )
        self.assertEqual(state["commits"], {})

    def test_stdout_cannot_capture_a_commit_without_matching_executor_evidence(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        args = dict(
            tool_name="Bash",
            tool_use_id="spoofed-exit",
            tool_input={"command": "git commit -m fixture"},
        )
        self.hook("PreToolUse", **args)
        (self.project / "file.txt").write_text("fixture")
        self.git("add", "file.txt")
        self.git("commit", "-m", "fixture")
        observed = self.hook(
            "PostToolUse",
            **args,
            tool_response={
                "output": "Process exited with code 1\nFinal output:\nProcess exited with code 0\n"
            },
        )
        state = json.loads(
            next(iter(self.state_paths())).read_text()
        )
        self.assertEqual(state["commits"], {})
        self.assertIn(
            "executor did not run", observed["hookSpecificOutput"]["additionalContext"]
        )

    def test_pending_capture_denies_next_commit_before_head_can_move(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        self.pending_commit()
        before = self.git("rev-parse", "HEAD").stdout
        result = self.hook(
            "PreToolUse",
            tool_name="Bash",
            tool_use_id="next-commit",
            tool_input={"command": "git commit -m next"},
        )
        self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, before)

    def test_git_environment_overrides_cannot_redirect_native_execution(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        other = self.directory / "other"
        other.mkdir()
        subprocess.run(
            ["git", "init", "-b", "other", str(other)],
            env=self.environment,
            check=True,
            capture_output=True,
        )
        (other / "other.txt").write_text("other repository")
        subprocess.run(
            ["git", "-C", str(other), "add", "other.txt"],
            env=self.environment,
            check=True,
        )
        (self.project / "file.txt").write_text("intended repository")
        self.git("add", "file.txt")
        self.environment.update(
            GIT_DIR=str(other / ".git"),
            GIT_WORK_TREE=str(other),
            GIT_INDEX_FILE=str(other / ".git/index"),
        )
        args = dict(
            tool_name="Bash",
            tool_use_id="isolated",
            tool_input={"command": "git commit -m fixture"},
        )
        rewritten = self.hook("PreToolUse", **args)
        executed = self.execute_rewritten(rewritten)
        self.assertEqual(executed.returncode, 0, executed.stderr)
        self.hook("PostToolUse", **args, tool_response=executed.stdout)
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            self.environment.pop(key)
        self.assertEqual(
            self.git("show", "--format=", "--name-only", "HEAD").stdout.strip(),
            "file.txt",
        )
        untouched = subprocess.run(
            ["git", "-C", str(other), "rev-parse", "--verify", "HEAD"],
            env=self.environment,
            capture_output=True,
        )
        self.assertNotEqual(untouched.returncode, 0)
        state = json.loads(
            next(iter(self.state_paths())).read_text()
        )
        self.assertEqual(len(state["commits"]), 1)
        self.assertEqual(state["snapshots"], {})

    def test_stale_event_is_rejected_without_synthesizing_history(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, _state, commit = self.pending_commit()
        (self.project / "file.txt").write_text("another commit")
        self.git("add", "file.txt")
        self.git("commit", "-m", "external fixture commit")
        failure = self.prepare(path, commit)
        self.assertEqual(failure.returncode, 64)
        self.assertIn("COMMIT_EVENT_REJECTED", failure.stderr)
        pending = json.loads(path.read_text())["commits"][commit]
        self.assertEqual(pending["status"], "pending")
        self.assertNotIn("native_arguments", pending)

    def test_sibling_commit_waits_until_pending_capture_is_resolved_by_owner(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        path, _state, commit = self.pending_commit()
        second_prompt = dict(
            self.event("UserPromptSubmit", prompt="session B"), session_id="session-2"
        )
        second_key = self.session_key("session-2")
        started = self.cli("hook", "--home", str(self.home), payload=second_prompt)
        self.assertEqual(started.returncode, 0, started.stderr)
        commit_event = dict(
            self.event(
                "PreToolUse",
                tool_name="Bash",
                tool_use_id="second-commit",
                tool_input={"command": "git commit -m sibling"},
            ),
            session_id="session-2",
        )
        before = self.cli("hook", "--home", str(self.home), payload=commit_event)
        self.assertEqual(before.returncode, 0, before.stderr)
        decision = json.loads(before.stdout)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn(path.stem, decision["permissionDecisionReason"])
        self.assertIn(second_key, decision["permissionDecisionReason"])
        status = self.cli(
            "status", "--home", str(self.home), "--session", path.stem
        )
        self.assertEqual(json.loads(status.stdout)["gate"]["session"], path.stem)
        prepared = self.prepare(path, commit)
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        arguments = json.loads(prepared.stdout)["arguments"]
        self.append_event(arguments)
        released = self.cli(
            "status", "--home", str(self.home), "--session", path.stem
        )
        self.assertIsNone(json.loads(released.stdout)["gate"])
        self.assertEqual(
            json.loads(path.read_text())["commits"][commit]["status"], "committed"
        )
        allowed = self.cli("hook", "--home", str(self.home), payload=commit_event)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertIn(
            "updatedInput", json.loads(allowed.stdout)["hookSpecificOutput"]
        )
        (self.project / "sibling.txt").write_text("sibling session change\n")
        self.git("add", "sibling.txt")
        executed = self.execute_rewritten(json.loads(allowed.stdout))
        self.assertEqual(executed.returncode, 0, executed.stderr)
        after = self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=dict(
                commit_event, hook_event_name="PostToolUse", tool_response=executed.stdout
            ),
        )
        self.assertEqual(after.returncode, 0, after.stderr)
        second_path = next(p for p in self.state_paths() if p != path)
        second_commit = next(iter(json.loads(second_path.read_text())["commits"]))
        prepared_second = self.prepare(second_path, second_commit)
        self.assertEqual(prepared_second.returncode, 0, prepared_second.stderr)
        self.assertEqual(
            json.loads(prepared_second.stdout)["arguments"]["idempotency_key"],
            json.loads(second_path.read_text())["commits"][second_commit][
                "native_arguments"
            ]["idempotency_key"],
        )

    def test_takeover_marks_interrupted_owner_inspectable_and_recoverable(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        path, _state, commit = self.pending_commit()
        head = self.git("rev-parse", "HEAD").stdout.strip()
        second_prompt = dict(
            self.event("UserPromptSubmit", prompt="session B"), session_id="session-2"
        )
        second_key = self.session_key("session-2")
        started = self.cli("hook", "--home", str(self.home), payload=second_prompt)
        self.assertEqual(started.returncode, 0, started.stderr)
        commit_event = dict(
            self.event(
                "PreToolUse",
                tool_name="Bash",
                tool_use_id="second-commit",
                tool_input={"command": "git commit -m sibling"},
            ),
            session_id="session-2",
        )
        denied = self.cli("hook", "--home", str(self.home), payload=commit_event)
        decision = json.loads(denied.stdout)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        unsigned = self.cli(
            "takeover", "--home", str(self.home), "--session", second_key
        )
        self.assertEqual(unsigned.returncode, 64)
        self.assertIn("INTERRUPTED_VERIFICATION_REQUIRED", unsigned.stderr)
        recovered = self.cli(
            "takeover",
            "--home",
            str(self.home),
            "--session",
            second_key,
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(json.loads(recovered.stdout)["owner"], path.stem)
        public = self.cli("status", "--home", str(self.home), "--session", path.stem)
        public_state = json.loads(public.stdout)
        self.assertIsNone(public_state["gate"])
        self.assertEqual(public_state["commits"][commit]["status"], "not_captured")
        self.assertEqual(public_state["commits"][commit]["event"]["commit"], head)
        resolution = public_state["snapshot_resolutions"][0]
        self.assertEqual(resolution["status"], "not_captured")
        self.assertEqual(resolution["taken_over_by"], second_key)
        self.assertEqual(resolution["commits"], [commit])
        blocked = self.cli(
            "takeover",
            "--home",
            str(self.home),
            "--session",
            second_key,
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(blocked.returncode, 64)
        self.assertIn("INTERRUPTED_OWNERSHIP_REQUIRED", blocked.stderr)
        allowed = self.cli("hook", "--home", str(self.home), payload=commit_event)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        (self.project / "sibling.txt").write_text("rescued session change\n")
        self.git("add", "sibling.txt")
        executed = self.execute_rewritten(json.loads(allowed.stdout))
        self.assertEqual(executed.returncode, 0, executed.stderr)
        after = self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=dict(
                commit_event, hook_event_name="PostToolUse", tool_response=executed.stdout
            ),
        )
        self.assertEqual(after.returncode, 0, after.stderr)
        second_path = next(p for p in self.state_paths() if p != path)
        second_commit = next(iter(json.loads(second_path.read_text())["commits"]))
        prepared_second = self.prepare(second_path, second_commit)
        self.assertEqual(prepared_second.returncode, 0, prepared_second.stderr)
        stale_owner = self.prepare(path, commit)
        self.assertEqual(stale_owner.returncode, 0, stale_owner.stderr)
        self.assertEqual(
            json.loads(stale_owner.stdout), {"status": "skipped", "path": None}
        )

    def load_native(self):
        script = self.bundle / "bin/obsidian-mcp-native"
        module = types.ModuleType("native_under_test")
        module.__file__ = str(script)
        exec(compile(script.read_text(), str(script), "exec"), module.__dict__)
        return module

    def sibling_commit_event(self):
        started = self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=dict(
                self.event("UserPromptSubmit", prompt="session B"),
                session_id="session-2",
            ),
        )
        self.assertEqual(started.returncode, 0, started.stderr)
        return dict(
            self.event(
                "PreToolUse",
                tool_name="Bash",
                tool_use_id="second-commit",
                tool_input={"command": "git commit -m sibling"},
            ),
            session_id="session-2",
        )

    def test_losing_second_claim_rolls_back_its_snapshot_and_denies(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        path, _state, _commit = self.pending_commit()
        commit_event = self.sibling_commit_event()
        native = self.load_native()
        home, profile = native.load_profile(self.home)
        real = native.active_request
        calls = []

        def unowned_at_first_check(directory):
            calls.append(directory)
            return None if len(calls) == 1 else real(directory)

        with mock.patch.object(native, "active_request", unowned_at_first_check):
            decision = native.hook(home, profile, commit_event)
        self.assertEqual(decision["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(path.stem, decision["hookSpecificOutput"]["permissionDecisionReason"])
        second_path = next(p for p in self.state_paths() if p != path)
        self.assertEqual(json.loads(second_path.read_text())["snapshots"], {})

    def test_disable_removes_the_gate_file(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        self.pending_commit()
        gate = self.home / "capture-state" / "active.json"
        self.assertTrue(gate.exists())
        self.assertEqual(self.cli("disable", "--home", str(self.home)).returncode, 0)
        self.assertFalse(gate.exists())

    def test_corrupt_gate_file_keeps_the_commit_event_and_takeover_clears_it(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        args = dict(
            tool_name="Bash",
            tool_use_id="commit-call",
            tool_input={"command": "git commit -m fixture"},
        )
        rewritten = self.hook("PreToolUse", **args)
        (self.project / "file.txt").write_text("fixture\n")
        self.git("add", "file.txt")
        executed = self.execute_rewritten(rewritten)
        self.assertEqual(executed.returncode, 0, executed.stderr)
        gate = self.home / "capture-state" / "active.json"
        gate.write_text("not json")
        after = self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=self.event("PostToolUse", **args, tool_response=executed.stdout),
        )
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertIn("ACTIVE_STATE_INVALID", after.stdout)
        path = next(iter(self.state_paths()))
        state = json.loads(path.read_text())
        self.assertEqual(state["snapshots"], {})
        self.assertEqual([c["status"] for c in state["commits"].values()], ["pending"])
        unsigned = self.cli("takeover", "--home", str(self.home), "--session", path.stem)
        self.assertEqual(unsigned.returncode, 64)
        self.assertTrue(gate.exists())
        cleared = self.cli(
            "takeover",
            "--home",
            str(self.home),
            "--session",
            path.stem,
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(cleared.returncode, 0, cleared.stderr)
        self.assertEqual(json.loads(cleared.stdout)["status"], "cleared_invalid_gate")
        self.assertFalse(gate.exists())

    def test_takeover_aborts_when_the_owner_releases_before_its_state_is_locked(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        path, _state, commit = self.pending_commit()
        second_key = self.session_key("session-2")
        native = self.load_native()
        home, profile = native.load_profile(self.home)
        gate = self.home / "capture-state" / "active.json"
        real = native.state_lock

        @contextmanager
        def owner_releases(directory, key):
            gate.unlink()
            with real(directory, key) as held:
                yield held

        arguments = types.SimpleNamespace(
            verification="command-stopped-and-history-inspected", session=second_key
        )
        with mock.patch.object(native, "state_lock", owner_releases):
            with self.assertRaises(native.NativeError) as raised:
                native.takeover(home, profile, arguments)
        self.assertEqual(str(raised.exception), "INTERRUPTED_OWNERSHIP_CHANGED")
        self.assertEqual(
            json.loads(path.read_text())["commits"][commit]["status"], "pending"
        )

    def test_owner_reclaim_keeps_the_original_since(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, state, _commit = self.pending_commit()
        gate = self.home / "capture-state" / "active.json"
        record = json.loads(gate.read_text())
        record["since"] = 1
        gate.write_text(json.dumps(record))
        native = self.load_native()
        home, _profile = native.load_profile(self.home)
        self.assertIsNone(native.claim_gate(home, path.stem, state))
        self.assertEqual(json.loads(gate.read_text())["since"], 1)

    def test_partial_commit_can_retry_only_original_payload_after_explicit_inspection(
        self,
    ):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, _state, commit = self.pending_commit()
        marker = "PRIVATE-COMMIT-CONTEXT-6291"
        prepared = self.prepare(path, commit, {"context": [marker]})
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        arguments = json.loads(prepared.stdout)["arguments"]

        def assert_status_redacted():
            before = path.read_bytes()
            public = self.cli(
                "status", "--home", str(self.home), "--session", path.stem
            )
            self.assertEqual(public.returncode, 0, public.stderr)
            self.assertNotIn(marker, public.stdout)
            self.assertNotIn(
                "native_arguments", json.loads(public.stdout)["commits"][commit]
            )
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(
                json.loads(before)["commits"][commit]["native_arguments"], arguments
            )

        assert_status_redacted()
        self.append_event(arguments, "partial")
        assert_status_redacted()
        pending = json.loads(path.read_text())["commits"][commit]
        retry_args = (
            "retry",
            "--home",
            str(self.home),
            "--session",
            path.stem,
            "--commit",
            commit,
            "--payload-sha256",
            pending["payload_digest"],
        )
        self.assertEqual(self.cli(*retry_args).returncode, 64)
        result = self.cli(*retry_args, "--verification", "authoritative-path-inspected")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["arguments"], arguments)
        self.append_event(arguments, call="reviewed-append")
        assert_status_redacted()
        self.assertEqual(
            json.loads(path.read_text())["commits"][commit]["status"], "committed"
        )

    def test_session_partial_preserves_payload_and_blocks_changed_or_unreviewed_retry(
        self,
    ):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path = next(iter(self.state_paths()))
        state = json.loads(path.read_text())
        plan = state["session_save"]
        args = dict(
            title=plan["title"],
            folder_hint=plan["folder"],
            body="Exact planning context",
            resolved=True,
            session_link_date=plan["date"],
            idempotency_key=plan["idempotency_key"],
        )
        event = dict(
            tool_name="mcp__obsidian_write__obsidian_keeper_save", tool_input=args
        )
        self.hook("PreToolUse", **event)
        self.hook(
            "PostToolUse",
            **event,
            tool_response={
                "isError": True,
                "structuredContent": {
                    "status": "partial",
                    "error_code": "PARTIAL",
                    "recovery": {"required": True},
                },
            },
        )
        state = json.loads(path.read_text())
        self.assertEqual(state["session_request"], args)
        self.assertEqual(state["session_outcome"]["status"], "partial")
        denied = self.hook("PreToolUse", **event)
        self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
        result = self.cli(
            "retry",
            "--home",
            str(self.home),
            "--session",
            path.stem,
            "--payload-sha256",
            state["session_payload_digest"],
            "--verification",
            "authoritative-path-inspected",
        )
        self.assertEqual(json.loads(result.stdout), args)
        changed = self.hook(
            "PreToolUse",
            tool_name=event["tool_name"],
            tool_input=dict(args, body="Changed"),
        )
        self.assertEqual(changed["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(self.hook("PreToolUse", **event), {})
        public = self.cli("status", "--home", str(self.home), "--session", path.stem)
        self.assertNotIn("Exact planning context", public.stdout)
        skip = self.cli(
            "skip",
            "--home",
            str(self.home),
            "--session",
            path.stem,
            "--turn",
            state["turn"],
            "--reason",
            "no_meaningful_work",
        )
        self.assertEqual(skip.returncode, 64)
        next_prompt = self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=dict(
                self.event("UserPromptSubmit", prompt="new"), turn_id="turn-2"
            ),
        )
        self.assertEqual(next_prompt.returncode, 64)
        self.assertEqual(json.loads(path.read_text())["session_request"], args)

    def test_interleaved_pre_events_deny_second_call_and_canceled_snapshot_is_resolvable(
        self,
    ):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        args = dict(
            tool_name="Bash",
            tool_use_id="first",
            tool_input={"command": "git commit -m first"},
        )
        rewritten = self.hook("PreToolUse", **args)
        self.assertIn("updatedInput", rewritten["hookSpecificOutput"])
        self.assertEqual(self.hook("PreToolUse", **args), rewritten)
        denied = self.hook(
            "PreToolUse",
            tool_name="Bash",
            tool_use_id="second",
            tool_input={"command": "git commit -m second"},
        )
        self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
        path = next(iter(self.state_paths()))
        snapshot = next(iter(json.loads(path.read_text())["snapshots"]))
        result = self.cli(
            "resolve-snapshot",
            "--home",
            str(self.home),
            "--session",
            path.stem,
            "--snapshot",
            snapshot,
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(path.read_text())
        self.assertEqual(state["snapshot_resolutions"][0]["status"], "not_captured")
        self.assertEqual(state["snapshots"], {})
        self.assertIn(
            "updatedInput",
            self.hook("PreToolUse", **dict(args, tool_use_id="third"))[
                "hookSpecificOutput"
            ],
        )

    def commit_args(self, call):
        return dict(
            tool_name="Bash",
            tool_use_id=call,
            tool_input={"command": "git commit -m fixture"},
        )

    def live_snapshot(self, call="commit-call"):
        rewritten = self.hook("PreToolUse", **self.commit_args(call))
        self.assertIn("updatedInput", rewritten["hookSpecificOutput"])
        path = next(iter(self.state_paths()))
        return path, next(iter(json.loads(path.read_text())["snapshots"]))

    def test_state_file_stem_matches_derived_session_key(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, _snapshot = self.live_snapshot()
        self.assertEqual(path.stem, self.session_key("session-1"))

    def resolve(self, key, snapshot):
        return self.cli(
            "resolve-snapshot",
            "--home",
            str(self.home),
            "--session",
            key,
            "--snapshot",
            snapshot,
            "--verification",
            "command-stopped-and-history-inspected",
        )

    def test_resolve_snapshot_releases_the_gate(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        key = self.session_key("session-1")
        _path, snapshot = self.live_snapshot()
        self.assertTrue((self.home / "capture-state" / "active.json").exists())
        resolved = self.resolve(key, snapshot)
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        result = json.loads(resolved.stdout)
        self.assertEqual(result["status"], "not_captured")
        self.assertNotIn("note", result)
        public = json.loads(
            self.cli("status", "--home", str(self.home), "--session", key).stdout
        )
        self.assertIsNone(public["gate"])
        self.assertEqual(public["snapshots"], {})

    def test_resolve_snapshot_warns_instead_of_failing_on_invalid_gate(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        key = self.session_key("session-1")
        _path, snapshot = self.live_snapshot()
        (self.home / "capture-state" / "active.json").write_text("not json")
        resolved = self.resolve(key, snapshot)
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        result = json.loads(resolved.stdout)
        self.assertEqual(result["status"], "not_captured")
        self.assertIn("ACTIVE_STATE_INVALID", result["note"])

    def test_dormant_executor_pops_snapshot_and_releases_gate(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        first_key = self.session_key("session-1")
        path, _snapshot = self.live_snapshot()
        gate = self.home / "capture-state" / "active.json"
        self.assertTrue(gate.exists())
        after = self.hook("PostToolUse", **self.commit_args("commit-call"))
        self.assertIn(
            "Commit executor did not run", after["hookSpecificOutput"]["additionalContext"]
        )
        public = json.loads(
            self.cli("status", "--home", str(self.home), "--session", first_key).stdout
        )
        self.assertIsNone(public["gate"])
        self.assertEqual(public["snapshots"], {})
        self.assertEqual(json.loads(path.read_text())["snapshots"], {})

    def test_takeover_carries_live_snapshots(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        self.git("commit", "--allow-empty", "-m", "base")
        path, snapshot = self.live_snapshot()
        head = self.git("rev-parse", "HEAD").stdout.strip()
        second_key = self.session_key("session-2")
        started = self.cli(
            "hook",
            "--home",
            str(self.home),
            payload=dict(
                self.event("UserPromptSubmit", prompt="session B"),
                session_id="session-2",
            ),
        )
        self.assertEqual(started.returncode, 0, started.stderr)
        recovered = self.cli(
            "takeover",
            "--home",
            str(self.home),
            "--session",
            second_key,
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        result = json.loads(recovered.stdout)
        self.assertEqual(result["status"], "recovered")
        self.assertEqual(result["owner"], path.stem)
        self.assertEqual(result["snapshots"], [snapshot])
        self.assertEqual(result["observed_head"], head)
        self.assertFalse(result["head_unavailable"])
        public = json.loads(
            self.cli("status", "--home", str(self.home), "--session", path.stem).stdout
        )
        record = public["snapshot_resolutions"][0]
        self.assertEqual(list(record["snapshots"]), [snapshot])
        self.assertEqual(public["snapshots"], {})

    def test_takeover_of_owner_without_pending_work_is_distinct(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        self.pending_commit()
        path = next(iter(self.state_paths()))
        owner_state = json.loads(path.read_text())
        owner_state["commits"] = {}
        owner_state["snapshots"] = {}
        path.write_text(json.dumps(owner_state))
        second_key = self.session_key("session-2")
        recovered = self.cli(
            "takeover",
            "--home",
            str(self.home),
            "--session",
            second_key,
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        result = json.loads(recovered.stdout)
        self.assertEqual(result["status"], "recovered_no_pending")
        self.assertEqual(result["commits"], [])
        self.assertNotIn("snapshots", result)
        self.assertIsNone(
            json.loads(
                self.cli("status", "--home", str(self.home), "--session", second_key).stdout
            )["gate"]
        )

    def test_gate_lock_blocks_across_processes(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, snapshot = self.live_snapshot()
        owner_key = path.stem
        second_key = self.session_key("session-2")
        lock = self.home / "capture-state" / "active.lock"
        self.assertTrue(lock.exists())
        holder = subprocess.Popen(
            [
                "python3",
                "-c",
                "import fcntl,os,sys,time\n"
                "fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR)\n"
                "fcntl.flock(fd,fcntl.LOCK_EX)\n"
                "print('HELD',flush=True)\n"
                "time.sleep(1.5)\n"
                "fcntl.flock(fd,fcntl.LOCK_UN)\n",
                str(lock),
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            line = holder.stdout.readline()
            self.assertEqual(line.strip(), "HELD")
            started = time.monotonic()
            takeover = self.cli(
                "takeover",
                "--home",
                str(self.home),
                "--session",
                second_key,
                "--verification",
                "command-stopped-and-history-inspected",
            )
            elapsed = time.monotonic() - started
            self.assertEqual(takeover.returncode, 0, takeover.stderr)
            result = json.loads(takeover.stdout)
            self.assertEqual(result["status"], "recovered")
            self.assertEqual(result["snapshots"], [snapshot])
            self.assertGreaterEqual(elapsed, 1.2)
            self.assertEqual(holder.wait(timeout=10), 0)
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.wait()

    def test_daily_append_on_invalid_gate_warns_instead_of_failing(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, _state, commit = self.pending_commit()
        prepared = self.prepare(path, commit)
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        arguments = json.loads(prepared.stdout)["arguments"]
        gate = self.home / "capture-state" / "active.json"
        gate.write_text("not json")
        before = self.hook(
            "PreToolUse",
            tool_name="mcp__obsidian_write__obsidian_daily_append",
            tool_use_id="append-1",
            tool_input=arguments,
        )
        self.assertNotIn(
            "permissionDecision", before.get("hookSpecificOutput", {})
        )
        after = self.hook(
            "PostToolUse",
            tool_name="mcp__obsidian_write__obsidian_daily_append",
            tool_use_id="append-1",
            tool_input=arguments,
            tool_response={
                "structuredContent": dict(
                    status="committed",
                    request_id="fixture-request",
                    idempotency_key=arguments["idempotency_key"],
                    path=arguments["target_path"],
                    affected_paths=[arguments["target_path"]],
                    warnings=[],
                    recovery={"required": False, "action": ""},
                    error_code=None,
                    retryable=False,
                ),
                "isError": False,
            },
        )
        self.assertIn(
            "ACTIVE_STATE_INVALID", after["hookSpecificOutput"]["additionalContext"]
        )
        state = json.loads(path.read_text())
        self.assertEqual(state["commits"][commit]["status"], "committed")

    def foreign_gate(self):
        gate = self.home / "capture-state" / "active.json"
        gate.write_text(
            json.dumps(
                dict(
                    schemaVersion=1,
                    session=self.session_key("session-2"),
                    reason="commit_capture",
                    since=1,
                )
            )
        )

    def test_hook_surfaces_foreign_gate_owner_note(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, _state, commit = self.pending_commit()
        arguments = json.loads(self.prepare(path, commit).stdout)["arguments"]
        self.foreign_gate()
        before = self.hook(
            "PreToolUse",
            tool_name="mcp__obsidian_write__obsidian_daily_append",
            tool_use_id="append-1",
            tool_input=arguments,
        )
        note = before["hookSpecificOutput"]["additionalContext"]
        self.assertIn("Unexpected capture-gate owner", note)
        self.assertIn(self.session_key("session-2"), note)

    def test_gate_note_is_kept_when_the_receipt_does_not_match(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, _state, commit = self.pending_commit()
        arguments = json.loads(self.prepare(path, commit).stdout)["arguments"]
        append = dict(
            tool_name="mcp__obsidian_write__obsidian_daily_append",
            tool_input=arguments,
        )
        self.hook("PreToolUse", tool_use_id="append-1", **append)
        (self.home / "capture-state" / "active.json").write_text("not json")
        after = self.hook(
            "PostToolUse",
            tool_use_id="append-2",
            tool_response={"isError": True},
            **append,
        )
        text = after["hookSpecificOutput"]["additionalContext"]
        self.assertIn("did not match", text)
        self.assertIn("ACTIVE_STATE_INVALID", text)

    def test_takeover_without_a_head_records_null_and_marks_it_unavailable(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        path, _snapshot = self.live_snapshot()
        second_key = self.session_key("session-2")
        recovered = self.cli(
            "takeover",
            "--home",
            str(self.home),
            "--session",
            second_key,
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        result = json.loads(recovered.stdout)
        self.assertEqual(result["status"], "recovered")
        self.assertIsNone(result["observed_head"])
        self.assertTrue(result["head_unavailable"])
        record = json.loads(path.read_text())["snapshot_resolutions"][0]
        self.assertIsNone(record["observed_head"])

    def test_resolve_snapshot_without_a_head_records_null(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="work")
        path, snapshot = self.live_snapshot()
        resolved = self.cli(
            "resolve-snapshot",
            "--home",
            str(self.home),
            "--session",
            path.stem,
            "--snapshot",
            snapshot,
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        record = json.loads(path.read_text())["snapshot_resolutions"][0]
        self.assertIsNone(record["observed_head"])

    def test_takeover_of_owner_with_missing_state_file_is_not_reported_clean(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        path, _snapshot = self.live_snapshot()
        path.unlink()
        recovered = self.cli(
            "takeover",
            "--home",
            str(self.home),
            "--session",
            self.session_key("session-2"),
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        result = json.loads(recovered.stdout)
        self.assertEqual(result["status"], "recovered_owner_state_missing")
        self.assertEqual(result["owner"], path.stem)

    def test_takeover_rejects_a_malformed_session_key(self):
        self.configure()
        self.hook("UserPromptSubmit", prompt="session A")
        self.live_snapshot()
        recovered = self.cli(
            "takeover",
            "--home",
            str(self.home),
            "--session",
            "not-hex",
            "--verification",
            "command-stopped-and-history-inspected",
        )
        self.assertNotEqual(recovered.returncode, 0)
        self.assertIn("SESSION_KEY_INVALID", recovered.stderr)


if __name__ == "__main__":
    unittest.main()
