#!/usr/bin/env python3
"""Exercise bundled MCP servers through an isolated, real Codex app-server."""

from __future__ import annotations

import json
import fcntl
import os
from pathlib import Path
import queue
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
CODEX = shutil.which("codex")
MOCK = """import json, sys
profile = sys.argv[1]
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if "id" not in request:
        continue
    if method == "initialize":
        result = {"protocolVersion":"2024-11-05", "capabilities":{"tools":{}}, "serverInfo":{"name":"fixture", "version":"1"}}
    elif method == "tools/list":
        names = ["obsidian_find_notes"] if profile == "read" else ["obsidian_keeper_save", "obsidian_daily_append"]
        result = {"tools":[{"name":name, "description":"fixture", "inputSchema":{"type":"object", "properties":{}}} for name in names]}
    elif method == "tools/call":
        result = {"content":[{"type":"text", "text":profile}]}
    else:
        result = {}
    print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":result}), flush=True)
"""


class AppServer:
    def __init__(self, env, cwd):
        self.process = subprocess.Popen(
            [CODEX, "app-server", "--stdio"],
            env=env,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            start_new_session=True,
        )
        self.messages = queue.Queue()
        self.sequence = 0
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.request(
            "initialize",
            {
                "clientInfo": {"name": "bundled-mcp-fixture", "version": "1"},
                "capabilities": {"experimentalApi": True},
            },
        )
        self.process.stdin.write('{"jsonrpc":"2.0","method":"initialized"}\n')
        self.process.stdin.flush()

    def read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))

    def request(self, method, params):
        self.sequence += 1
        identity = self.sequence
        self.process.stdin.write(
            json.dumps(
                {"jsonrpc": "2.0", "id": identity, "method": method, "params": params}
            )
            + "\n"
        )
        self.process.stdin.flush()
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=deadline - time.monotonic())
            except queue.Empty:
                break
            if message.get("id") == identity:
                if "error" in message:
                    raise AssertionError(f"{method}: {message['error']}")
                return message["result"]
        raise AssertionError(f"{method}: isolated app-server response timed out")

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        if self.reader.is_alive():
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            self.reader.join(timeout=2)
        if self.reader.is_alive():
            raise AssertionError("fixture app-server did not close its output")
        self.process.stdout.close()


class LoaderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="codex-connection-runtime-")
        cls.bundle = Path(cls.fixture.name).resolve() / "bundle"
        packer = runpy.run_path(str(ROOT / "scripts/pack-obsidian-mcp-client.py"))
        files = packer["source_files"](
            ROOT / "packages/client/catalog.json",
            ROOT / "packages/mcp-server/contract.json",
        )
        for profile in ("read", "write"):
            admission = '\nimport os\nfrom pathlib import Path\nprefix = "OBSIDIAN_MCP_" + sys.argv[-1].upper()\nassert os.environ[prefix + "_ENDPOINT"] == "https://fixture.invalid/mcp"\nassert os.environ[prefix + "_CREDENTIAL_PROVIDER"] == "file"\nassert Path(os.environ[prefix + "_TOKEN_FILE"]).name == sys.argv[-1] + ".ref"\nassert "OBSIDIAN_MCP_WRITE_AUTHORIZATION" not in os.environ\nassert "UNAPPROVED_FIXTURE_TOKEN" not in os.environ\n'
            files["bin/obsidian-mcp-" + profile] = (
                "#!"
                + sys.executable
                + "\nimport sys\nsys.argv.append("
                + repr(profile)
                + ")\n"
                + admission
                + MOCK
            ).encode()
        for relative, data in files.items():
            path = cls.bundle / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o755 if relative in packer["EXECUTABLES"] else 0o644)
        cls.metadata = packer["release_metadata"](files)
        (cls.bundle / "release.json").write_bytes(cls.metadata)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.assertIsNotNone(CODEX, "actual Codex CLI required")
        self.temp = tempfile.TemporaryDirectory(prefix="codex-bundled-mcp-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        self.codex_home = self.root / "chosen codex"
        self.codex_home.mkdir(mode=0o700)
        (self.codex_home / ".tmp").mkdir()
        self.sync_lock = (self.codex_home / ".tmp/plugins.sync.lock").open("w")
        fcntl.flock(self.sync_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(self.sync_lock.close)
        self.env = {
            "HOME": str(self.home),
            "CODEX_HOME": str(self.codex_home),
            "PATH": os.path.dirname(sys.executable)
            + ":"
            + str(Path(CODEX).parent)
            + ":/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
            "XDG_STATE_HOME": str(self.home / "state"),
            "XDG_CONFIG_HOME": str(self.home / "config"),
            "XDG_CACHE_HOME": str(self.home / "cache"),
        }
        self.checkout = self.root / "marketplace"
        self.checkout.mkdir()
        shutil.copytree(ROOT / "packages/codex", self.checkout / "packages/codex")
        shutil.copytree(ROOT / ".agents", self.checkout / ".agents")
        self.package = self.checkout / "packages/codex"
        mutation = os.environ.get("CODEX_BUNDLED_TEST_MUTATION")
        if mutation:
            self.mutate(mutation)
        self.mock = self.root / "mock.py"
        self.mock.write_text(MOCK)
        self.config = self.codex_home / "config.toml"
        self.config.write_text(
            'model = "fixture"\nmodel_provider = "fixture"\n[features]\nremote_plugin = false\nplugins = true\n[model_providers.fixture]\nname = "fixture"\nbase_url = "http://127.0.0.1:9/v1"\nwire_api = "responses"\nrequires_openai_auth = false\n'
        )
        self.config.chmod(0o600)
        self.prefix = self.home / "runtime with spaces"
        self.state = self.home / "state/claude-obsidian"
        self.state.mkdir(parents=True)
        (self.state / "capture-ownership").mkdir(mode=0o700)
        self.owner = self.state / "capture-ownership/owner.json"
        self.owner_bytes = (
            b'{"schema":1,"owner":"mcp","generation":8,"phase":"stable","profiles":{}}'
        )
        self.owner.write_bytes(self.owner_bytes)
        self.owner.chmod(0o600)
        self.env.update(
            OBSIDIAN_MCP_WRITE_AUTHORIZATION="fixture-unapproved",
            UNAPPROVED_FIXTURE_TOKEN="fixture-unapproved",
        )

    def mutate(self, name):
        script = self.package / "scripts/connection.py"
        text = script.read_text()
        if name == "wiring":
            (self.package / ".mcp.json").unlink()
            return
        if name == "verification":
            before = '        CAPTURE["codex_verify"]('
            lines = text.splitlines(keepends=True)
            start = next(i for i, line in enumerate(lines) if before in line)
            end = start + 1
            while end < len(lines) and not lines[end].startswith(
                "        yield bundle"
            ):
                end += 1
            lines[start:end] = ["        pass\n"]
            script.write_text("".join(lines))
            return
        if name == "slots":
            before = (
                '        if slots["current"] is None or slots["disabled"] is not None:'
            )
            after = '        slots["current"] = slots["current"] or slots["disabled"]\n        if slots["current"] is None:'
        elif name == "preview":
            before, after = "        if args.apply:", "        if True:"
        elif name == "policy":
            before, after = (
                '            if existing != {"default_tools_approval_mode": "auto"}:',
                "            if False:",
            )
        elif name == "credential-read":
            before = '        path = absolute(value["path"])'
            after = before + "\n        path.read_bytes()"
        else:
            raise AssertionError("unknown fixture mutation")
        self.assertIn(before, text)
        script.write_text(text.replace(before, after, 1))

    def runtime(self):
        import hashlib

        pin_path = self.package / "skills/setup/scripts/client-v0.3.1.pin.json"
        pin = json.loads(pin_path.read_bytes())
        pin["releaseId"] = json.loads(self.metadata)["releaseId"]
        digest = hashlib.sha256(self.metadata).hexdigest()
        pin["assets"]["obsidian-mcp-client.release.json"] = {
            "sha256": digest,
            "size": len(self.metadata),
        }
        pin_path.write_text(json.dumps(pin))
        installer = (
            self.package
            / "skills/commit-capture/scripts/lib/obsidian-mcp-client-install"
        )
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(installer),
                "--prefix",
                str(self.prefix),
                "--bundle",
                str(self.bundle),
                "--release-sha256",
                digest,
            ],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.tokens = []
        for profile in ("read", "write"):
            path = self.home / (profile + ".ref")
            path.write_text("fixture-not-a-credential")
            path.chmod(0o600)
            self.tokens.append(path)

    def configure(self, *arguments, expected=0, installed=False):
        version = json.loads((self.package / ".codex-plugin/plugin.json").read_bytes())[
            "version"
        ]
        package = (
            self.codex_home / "plugins/cache/nhangen-codex-plugins/obsidian" / version
            if installed
            else self.package
        )
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                str(package / "scripts/connection.py"),
                "setup",
                "--runtime-prefix",
                str(self.prefix),
                "--endpoint",
                "https://fixture.invalid/mcp",
                "--read-token-file",
                str(self.tokens[0]),
                "--write-token-file",
                str(self.tokens[1]),
                *arguments,
            ],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        return result

    def inventory(self):
        server, thread = self.start()
        data = self.catalog(server, thread)
        return server, thread, {item["name"]: item for item in data}

    def catalog(self, server, thread):
        deadline = time.monotonic() + 5
        while True:
            data = server.request("mcpServerStatus/list", {"threadId": thread})["data"]
            pending = {
                item["name"]: item["runtimeStatus"]
                for item in data
                if item["runtimeStatus"] in ("starting", "notStarted")
            }
            if not pending:
                return data
            self.assertLess(
                time.monotonic(),
                deadline,
                f"fixture MCP startup did not settle: {pending}",
            )
            time.sleep(0.05)

    def assert_unchanged_capture(self):
        self.assertEqual(self.owner.read_bytes(), self.owner_bytes)
        self.assertEqual(
            sorted(str(path.relative_to(self.state)) for path in self.state.rglob("*")),
            ["capture-ownership", "capture-ownership/owner.json"],
        )
        self.assertEqual(
            list((self.codex_home / ".tmp").glob("plugins-clone-*")),
            [],
            "fixture allowed unrelated curated-marketplace sync",
        )

    def trust_snapshot(self, server):
        data = server.request("hooks/list", {"cwds": [str(self.home)]})["data"]
        hooks = [
            hook
            for entry in data
            for hook in entry["hooks"]
            if hook.get("pluginId") == "obsidian@nhangen-codex-plugins"
        ]
        self.assertTrue(hooks, "actual CLI must expose installed hook trust metadata")
        return sorted(
            (hook["key"], hook["currentHash"], hook["trustStatus"], hook["enabled"])
            for hook in hooks
        )

    def install(self):
        for arguments in (
            ("plugin", "marketplace", "add", str(self.checkout)),
            ("plugin", "add", "obsidian@nhangen-codex-plugins"),
        ):
            result = subprocess.run(
                [CODEX, *arguments],
                env=self.env,
                cwd=self.home,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def start(self):
        server = AppServer(self.env, self.home)
        self.addCleanup(server.close)
        thread = server.request(
            "thread/start",
            {
                "cwd": str(self.home),
                "ephemeral": True,
                "model": "fixture",
                "modelProvider": "fixture",
            },
        )
        return server, thread["thread"]["id"]

    def test_loader_plugin_relative_cwd_and_canonical_names(self):
        manifest = self.package / ".codex-plugin/plugin.json"
        value = json.loads(manifest.read_text())
        value["mcpServers"] = "./.mcp.json"
        manifest.write_text(json.dumps(value))
        self.mock.replace(self.package / "mock.py")
        (self.package / ".mcp.json").write_text(
            json.dumps(
                {
                    "mcpServers": {
                        name: {
                            "command": sys.executable,
                            "args": ["-I", "-B", "mock.py", profile],
                            "cwd": ".",
                        }
                        for name, profile in (
                            ("obsidian", "read"),
                            ("obsidian-write", "write"),
                        )
                    }
                }
            )
        )
        self.install()
        installed_mock = (
            self.codex_home
            / "plugins/cache/nhangen-codex-plugins/obsidian/1.27.0/mock.py"
        )
        self.assertTrue(installed_mock.is_file(), "installed mock absent")
        server, thread = self.start()
        data = self.catalog(server, thread)
        self.assertEqual(
            sorted(item["name"] for item in data), ["obsidian", "obsidian-write"]
        )
        for item in data:
            self.assertTrue(item["tools"], item)
        result = server.request(
            "mcpServer/tool/call",
            {
                "threadId": thread,
                "server": "obsidian",
                "tool": "obsidian_find_notes",
                "arguments": {},
            },
        )
        self.assertIn("read", json.dumps(result))

    def test_shipped_package_registers_both_servers(self):
        self.runtime()
        self.install()
        before_server = AppServer(self.env, self.home)
        try:
            trust_before = self.trust_snapshot(before_server)
        finally:
            before_server.close()
        original = self.config.read_bytes()
        result = self.configure(installed=True)
        self.assertEqual(json.loads(result.stdout)["status"], "preview")
        self.assertFalse((self.codex_home / "obsidian-connection.json").exists())
        self.assertEqual(self.config.read_bytes(), original)
        self.configure("--apply", "--authorize-routine-tools", installed=True)
        server, thread, data = self.inventory()
        self.assertEqual(self.trust_snapshot(server), trust_before)
        settings = server.request("config/read", {})["config"]
        policies = settings["plugins"]["obsidian@nhangen-codex-plugins"]["mcp_servers"]
        self.assertEqual(
            policies["obsidian-write"]["default_tools_approval_mode"], "auto"
        )
        self.assertEqual(policies["obsidian"]["default_tools_approval_mode"], "auto")
        self.assertEqual(sorted(data), ["obsidian", "obsidian-write"])
        self.assertEqual(set(data["obsidian"]["tools"]), {"obsidian_find_notes"})
        self.assertEqual(
            set(data["obsidian-write"]["tools"]),
            {"obsidian_keeper_save", "obsidian_daily_append"},
        )
        result = server.request(
            "mcpServer/tool/call",
            {
                "threadId": thread,
                "server": "obsidian",
                "tool": "obsidian_find_notes",
                "arguments": {},
            },
        )
        self.assertIn("read", json.dumps(result))
        self.assert_unchanged_capture()

    def test_disabled_and_tampered_runtime_never_starts(self):
        self.runtime()
        self.configure("--apply")
        self.install()
        for failure in ("disabled", "tampered", "transition", "missing"):
            with self.subTest(failure=failure):
                current = self.prefix / "current"
                bundle = current.resolve()
                if failure == "disabled":
                    current.rename(self.prefix / "disabled")
                elif failure == "tampered":
                    (bundle / "README.md").write_text("tampered")
                elif failure == "transition":
                    (self.prefix / ".transition.json").write_text("{}")
                else:
                    current.unlink()
                try:
                    _, _, data = self.inventory()
                    self.assertEqual(set(data), {"obsidian", "obsidian-write"})
                    self.assertTrue(
                        all(
                            not item["tools"] and item["runtimeStatus"] == "failed"
                            for item in data.values()
                        ),
                        {
                            name: {
                                "status": item["runtimeStatus"],
                                "tools": list(item["tools"]),
                            }
                            for name, item in data.items()
                        },
                    )
                finally:
                    if failure == "disabled":
                        (self.prefix / "disabled").rename(current)
                    elif failure == "tampered":
                        (bundle / "README.md").write_bytes(
                            (self.bundle / "README.md").read_bytes()
                        )
                    elif failure == "transition":
                        (self.prefix / ".transition.json").unlink()
                    else:
                        current.symlink_to("releases/" + bundle.name)
                self.assert_unchanged_capture()

    def test_verifier_and_release_pin_tampering_is_refused(self):
        self.runtime()
        self.configure("--apply")
        self.install()
        installed = (
            self.codex_home / "plugins/cache/nhangen-codex-plugins/obsidian/1.27.0"
        )
        for relative in (
            "skills/commit-capture/scripts/lib/obsidian-mcp-client-install",
            "skills/setup/scripts/client-v0.3.1.pin.json",
        ):
            with self.subTest(relative=relative):
                path = installed / relative
                original = path.read_bytes()
                if relative.endswith(".json"):
                    pin = json.loads(original)
                    pin["assets"]["obsidian-mcp-client.release.json"]["sha256"] = (
                        "0" * 64
                    )
                    path.write_text(json.dumps(pin))
                else:
                    path.write_bytes(original + b"\n")
                try:
                    _, _, data = self.inventory()
                    self.assertEqual(set(data), {"obsidian", "obsidian-write"})
                    self.assertTrue(
                        all(
                            item["runtimeStatus"] == "failed" and not item["tools"]
                            for item in data.values()
                        )
                    )
                finally:
                    path.write_bytes(original)
                self.assert_unchanged_capture()

    def test_global_winner_restrictions_and_disabled_policy(self):
        self.runtime()
        self.configure("--apply")
        self.install()
        with self.config.open("a") as output:
            output.write(
                "\n[mcp_servers.obsidian]\ncommand = "
                + json.dumps(sys.executable)
                + "\nargs = "
                + json.dumps([str(self.mock), "global"])
                + '\ndisabled_tools = ["obsidian_daily_append"]\ndefault_tools_approval_mode = "prompt"\n[plugins."obsidian@nhangen-codex-plugins".mcp_servers."obsidian-write"]\nenabled = false\n'
            )
        before = self.config.read_bytes()
        self.configure("--apply", "--authorize-routine-tools", expected=64)
        self.assertEqual(self.config.read_bytes(), before)
        server, thread, data = self.inventory()
        self.assertEqual(sorted(data), ["obsidian", "obsidian-write"])
        self.assertEqual(data["obsidian-write"]["runtimeStatus"], "disabled")
        self.assertFalse(data["obsidian-write"]["tools"])
        self.assertIsNone(data["obsidian"].get("pluginId"))
        self.assertEqual(set(data["obsidian"]["tools"]), {"obsidian_keeper_save"})
        result = server.request(
            "mcpServer/tool/call",
            {
                "threadId": thread,
                "server": "obsidian",
                "tool": "obsidian_keeper_save",
                "arguments": {},
            },
        )
        self.assertIn("global", json.dumps(result))
        settings = server.request("config/read", {})["config"]
        self.assertEqual(
            settings["mcp_servers"]["obsidian"]["default_tools_approval_mode"], "prompt"
        )
        self.assert_unchanged_capture()

    def test_global_disabled_wins_and_plugin_tool_filter_is_retained(self):
        self.runtime()
        self.configure("--apply")
        self.install()
        with self.config.open("a") as output:
            output.write(
                '\n[mcp_servers.obsidian]\ncommand = "/fixture/must-not-run"\nenabled = false\n[plugins."obsidian@nhangen-codex-plugins".mcp_servers."obsidian-write"]\nenabled_tools = ["obsidian_keeper_save"]\n'
            )
        original = self.config.read_bytes()
        _, _, data = self.inventory()
        self.assertEqual(set(data), {"obsidian", "obsidian-write"})
        self.assertEqual(data["obsidian"]["runtimeStatus"], "disabled")
        self.assertFalse(data["obsidian"]["tools"])
        self.assertIsNone(data["obsidian"].get("pluginId"))
        self.assertEqual(set(data["obsidian-write"]["tools"]), {"obsidian_keeper_save"})
        self.assertEqual(self.config.read_bytes(), original)
        self.assert_unchanged_capture()

    def test_config_and_credential_references_fail_closed(self):
        self.runtime()
        self.configure("--apply")
        record = self.codex_home / "obsidian-connection.json"
        original = record.read_bytes()
        script = self.package / "scripts/connection.py"
        for failure in (
            "unknown_provider",
            "token_mode",
            "config_mode",
            "empty_home",
            "unknown_schema",
        ):
            with self.subTest(failure=failure):
                value = json.loads(original)
                environment = self.env.copy()
                if failure == "unknown_provider":
                    value["credentials"]["read"]["provider"] = "fiel"
                elif failure == "token_mode":
                    self.tokens[0].chmod(0o644)
                elif failure == "config_mode":
                    record.chmod(0o644)
                elif failure == "empty_home":
                    environment["CODEX_HOME"] = ""
                else:
                    value["schemaVersion"] = 2
                record.write_text(json.dumps(value))
                result = subprocess.run(
                    [sys.executable, "-I", "-B", str(script), "read"],
                    env=environment,
                    capture_output=True,
                    timeout=5,
                )
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertEqual(result.stdout, b"")
                record.chmod(0o600)
                record.write_bytes(original)
                self.tokens[0].chmod(0o600)

    def test_missing_config_never_installs_or_changes_capture(self):
        self.install()
        original = self.config.read_bytes()
        _, _, data = self.inventory()
        self.assertEqual(set(data), {"obsidian", "obsidian-write"})
        self.assertTrue(
            all(
                item["runtimeStatus"] == "failed" and not item["tools"]
                for item in data.values()
            )
        )
        self.assertFalse(self.prefix.exists())
        self.assertFalse((self.codex_home / "obsidian-connection.json").exists())
        self.assertEqual(self.config.read_bytes(), original)
        self.assert_unchanged_capture()

    def test_setup_conflicts_and_idempotence_preserve_policy(self):
        self.runtime()
        original = self.config.read_bytes()
        self.configure("--apply")
        self.configure("--apply")
        self.assertEqual(self.config.read_bytes(), original)
        record = self.codex_home / "obsidian-connection.json"
        before = record.read_bytes()
        value = json.loads(before)
        value["endpoint"] = "https://different.invalid/mcp"
        record.write_text(json.dumps(value))
        self.configure("--apply", expected=64)
        self.assertEqual(self.config.read_bytes(), original)
        record.write_bytes(before)
        for policy in (
            '[plugins."obsidian@nhangen-codex-plugins".mcp_servers.obsidian]\ndefault_tools_approval_mode = "prompt"\n',
            "[plugins._default]\nenabled = false\n",
            '[profiles.fixture]\nmodel = "fixture"\n',
        ):
            with self.subTest(policy=policy):
                self.config.write_bytes(original + policy.encode())
                expected = self.config.read_bytes()
                self.configure("--apply", "--authorize-routine-tools", expected=64)
                self.assertEqual(self.config.read_bytes(), expected)
                self.assertEqual(record.read_bytes(), before)
        self.assert_unchanged_capture()

    def test_setup_never_reads_credential_references(self):
        self.runtime()
        arguments = [
            "setup",
            "--runtime-prefix",
            str(self.prefix),
            "--endpoint",
            "https://fixture.invalid/mcp",
            "--read-token-file",
            str(self.tokens[0]),
            "--write-token-file",
            str(self.tokens[1]),
            "--apply",
        ]
        harness = """import builtins, io, os, pathlib, runpy, subprocess, sys
script, refs, *args = sys.argv[1:]
forbidden = set(refs.split(os.pathsep))
def protect(function):
    def guarded(path, *a, **kw):
        if isinstance(path, (str, pathlib.Path)) and str(path) in forbidden:
            raise AssertionError("setup attempted credential read")
        return function(path, *a, **kw)
    return guarded
builtins.open = protect(builtins.open)
io.open = protect(io.open)
os.open = protect(os.open)
def no_provider(*args, **kwargs):
    raise AssertionError("setup attempted a subprocess")
subprocess.run = no_provider
subprocess.Popen = no_provider
sys.argv = [script, *args]
runpy.run_path(script, run_name="__main__")
"""
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                "-c",
                harness,
                str(self.package / "scripts/connection.py"),
                os.pathsep.join(map(str, self.tokens)),
                *arguments,
            ],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_inline_host_policy_conflict_refuses_before_writing(self):
        self.runtime()
        self.config.write_text(
            'plugins = {"obsidian@nhangen-codex-plugins" = {enabled = true}}\n'
        )
        original = self.config.read_bytes()
        self.configure("--apply", "--authorize-routine-tools", expected=64)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.codex_home / "obsidian-connection.json").exists())

    def test_existing_chat_reload_and_two_workspaces_share_one_home(self):
        self.runtime()
        self.install()
        first = self.root / "workspace one"
        second = self.root / "workspace two"
        first.mkdir()
        second.mkdir()
        server = AppServer(self.env, first)
        self.addCleanup(server.close)
        thread = server.request(
            "thread/start",
            {
                "cwd": str(first),
                "ephemeral": True,
                "model": "fixture",
                "modelProvider": "fixture",
            },
        )["thread"]["id"]
        before = self.catalog(server, thread)
        self.assertEqual(
            {item["name"] for item in before}, {"obsidian", "obsidian-write"}
        )
        self.assertTrue(all(not item["tools"] for item in before))
        self.configure("--apply", installed=True)
        record = self.codex_home / "obsidian-connection.json"
        original = record.read_bytes()
        server.request("config/mcpServer/reload", None)
        for cwd, identity in ((first, thread), (second, None)):
            with self.subTest(cwd=cwd.name):
                if identity is None:
                    identity = server.request(
                        "thread/start",
                        {
                            "cwd": str(cwd),
                            "ephemeral": True,
                            "model": "fixture",
                            "modelProvider": "fixture",
                        },
                    )["thread"]["id"]
                after = self.catalog(server, identity)
                self.assertEqual(
                    {item["name"] for item in after}, {"obsidian", "obsidian-write"}
                )
                self.assertTrue(all(item["tools"] for item in after))
                result = server.request(
                    "mcpServer/tool/call",
                    {
                        "threadId": identity,
                        "server": "obsidian",
                        "tool": "obsidian_find_notes",
                        "arguments": {},
                    },
                )
                self.assertIn("read", json.dumps(result))
                self.assertEqual(record.read_bytes(), original)
                self.assertEqual(
                    list(cwd.iterdir()), [], "connection setup enrolled a workspace"
                )
                self.assert_unchanged_capture()

    def test_skills_only_install_upgrades_and_reloads_same_chat(self):
        self.runtime()
        manifest = self.package / ".codex-plugin/plugin.json"
        candidate = json.loads(manifest.read_bytes())
        declarations = (self.package / ".mcp.json").read_bytes()
        old = {
            key: value
            for key, value in candidate.items()
            if key not in ("mcpServers", "hooks")
        }
        manifest.write_text(json.dumps(old))
        (self.package / ".mcp.json").unlink()
        shutil.rmtree(self.package / "hooks")
        self.install()
        server, thread, before = self.inventory()
        self.assertEqual(
            before, {}, "old skills-only package unexpectedly supplied MCP servers"
        )
        candidate["version"] = "1.27.1-fixture"
        manifest.write_text(json.dumps(candidate))
        (self.package / ".mcp.json").write_bytes(declarations)
        shutil.copytree(ROOT / "packages/codex/hooks", self.package / "hooks")
        server.request(
            "plugin/install",
            {
                "marketplacePath": str(
                    self.checkout / ".agents/plugins/marketplace.json"
                ),
                "pluginName": "obsidian",
            },
        )
        installed = (
            self.codex_home
            / "plugins/cache/nhangen-codex-plugins/obsidian/1.27.1-fixture"
        )
        self.assertTrue(
            (installed / ".mcp.json").is_file(),
            "supported install did not materialize the candidate",
        )
        self.configure("--apply", installed=True)
        server.request("config/mcpServer/reload", None)
        after = self.catalog(server, thread)
        self.assertEqual(
            {item["name"] for item in after}, {"obsidian", "obsidian-write"}
        )
        self.assertTrue(all(item["tools"] for item in after))
        result = server.request(
            "mcpServer/tool/call",
            {
                "threadId": thread,
                "server": "obsidian",
                "tool": "obsidian_find_notes",
                "arguments": {},
            },
        )
        self.assertIn("read", json.dumps(result))
        self.assertTrue(
            all(hook[2] == "untrusted" for hook in self.trust_snapshot(server))
        )
        self.assert_unchanged_capture()


if __name__ == "__main__":
    unittest.main()
