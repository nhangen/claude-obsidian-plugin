#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib


def require(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


codex = shutil.which("codex")
require(codex is not None, "actual Codex CLI is required")
skill = Path(sys.argv[1]) / "packages/codex/skills/setup/SKILL.md"
text = skill.read_text()
blocks = {}
for label in ("inventory", "inspect", "add-file", "add-keychain"):
    match = re.search(r"<!-- connection-" + label + r" -->\n```bash\n(.*?)\n```", text, re.S)
    require(match is not None, "missing executable connection example: " + label)
    blocks[label] = match.group(1)

with tempfile.TemporaryDirectory(prefix="codex-connection-") as temporary:
    root = Path(temporary).resolve()
    home, target, cwd = (root / name for name in ("home", "chosen-codex", "work"))
    for directory in (home, target, cwd, root / "tmp"):
        directory.mkdir()
    client = root / "runtime with spaces/current"
    (client / "bin").mkdir(parents=True)
    for profile in ("read", "write"):
        launcher = client / "bin" / ("obsidian-mcp-" + profile)
        launcher.write_text('#!/bin/sh\ntouch "' + str(root / "unexpected-launch") + '"\nexit 99\n')
        launcher.chmod(0o700)
        reference = root / (profile + " reference")
        reference.touch(mode=0o600)
    env = {
        "HOME": str(home), "CODEX_HOME": str(target), "PATH": os.environ["PATH"],
        "TMPDIR": str(root / "tmp"), "XDG_CONFIG_HOME": str(home / "config"),
        "XDG_STATE_HOME": str(home / "state"), "XDG_CACHE_HOME": str(home / "cache"),
        "OBSIDIAN_CLIENT": str(client),
        "OBSIDIAN_ENDPOINT": "https://example.invalid/mcp",
        "OBSIDIAN_CONNECTION_PROVIDER": "file",
    }

    def run(command, *, ok=True):
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                                text=True, timeout=20)
        require((result.returncode == 0) == ok, "unexpected CLI/example exit status")
        require("DO_NOT_DISPLAY_FIXTURE_VALUE" not in result.stdout + result.stderr,
                "inspection exposed an unapproved value")
        return result.stdout.strip()

    def example(label, *, ok=True):
        return run(["bash", "-euo", "pipefail", "-c", blocks[label]], ok=ok)

    def select(profile, provider="file"):
        env.update(OBSIDIAN_CONNECTION_NAME="obsidian" if profile == "read" else "obsidian-write",
                   OBSIDIAN_CONNECTION_PROFILE=profile.upper(),
                   OBSIDIAN_CONNECTION_LAUNCHER=profile,
                   OBSIDIAN_CONNECTION_PROVIDER=provider,
                   OBSIDIAN_CONNECTION_TOKEN_FILE=str(root / (profile + " reference")),
                   OBSIDIAN_CONNECTION_KEYCHAIN_SERVICE="fixture-" + profile,
                   OBSIDIAN_CONNECTION_KEYCHAIN_ACCOUNT="fixture-account")

    config = target / "config.toml"
    config.write_text('model = "fixture-model"\n[mcp_servers.unrelated]\n'
                      'command = "/fixture/unrelated"\n'
                      'default_tools_approval_mode = "prompt"\n'
                      '[mcp_servers.unrelated.env]\n'
                      'FIXTURE_VALUE = "DO_NOT_DISPLAY_FIXTURE_VALUE"\n')
    original = tomllib.loads(config.read_text())
    inventory = json.loads(example("inventory"))
    require(inventory == {"obsidian": "absent", "obsidian-write": "absent"},
            "fresh inventory did not report both names absent")
    select("read")
    example("inspect", ok=False)
    require(tomllib.loads(config.read_text()) == original, "missing get changed configuration")
    for profile in ("read", "write"):
        select(profile)
        require(json.loads(example("inventory"))[env["OBSIDIAN_CONNECTION_NAME"]] == "absent",
                "immediate pre-add check failed")
        example("add-file")
        require(example("inspect") == "MATCH", "file registration differs from plan")
    actual = tomllib.loads(config.read_text())
    require(actual["model"] == original["model"] and
            actual["mcp_servers"]["unrelated"] == original["mcp_servers"]["unrelated"],
            "unrelated settings changed")
    for name, profile in (("obsidian", "READ"), ("obsidian-write", "WRITE")):
        entry = actual["mcp_servers"][name]
        require(entry["command"] == str(client / "bin" / ("obsidian-mcp-" + profile.lower())),
                "wrong launcher")
        require(entry["env"] == {
            "OBSIDIAN_MCP_" + profile + "_ENDPOINT": env["OBSIDIAN_ENDPOINT"],
            "OBSIDIAN_MCP_" + profile + "_CREDENTIAL_PROVIDER": "file",
            "OBSIDIAN_MCP_" + profile + "_TOKEN_FILE": str(root / (profile.lower() + " reference")),
        }, "registration must contain references only")
        require("default_tools_approval_mode" not in entry, "registration granted approval policy")
    config.write_text(config.read_text().replace(
        "[mcp_servers.obsidian]\n",
        '[mcp_servers.obsidian]\ndefault_tools_approval_mode = "prompt"\n', 1))
    require(tomllib.loads(config.read_text())["mcp_servers"]["obsidian"]["default_tools_approval_mode"] == "prompt",
            "approval-policy fixture is missing")
    before = config.read_bytes()
    require(json.loads(example("inventory")) == {"obsidian": "present", "obsidian-write": "present"},
            "matching rerun inventory failed")
    for profile in ("read", "write"):
        select(profile)
        require(example("inspect") == "MATCH", "matching rerun failed")
    require(config.read_bytes() == before, "inspection changed configuration")
    select("read")
    env["OBSIDIAN_ENDPOINT"] = "https://different.invalid/mcp"
    require(example("inspect") == "CONFLICT", "differing registration was accepted")
    require(config.read_bytes() == before, "conflict changed configuration")
    env["OBSIDIAN_ENDPOINT"] = "https://example.invalid/mcp"
    config.write_text(config.read_text().replace(
        "[mcp_servers.obsidian.env]\n",
        '[mcp_servers.obsidian.env]\nFIXTURE_VALUE = "DO_NOT_DISPLAY_FIXTURE_VALUE"\n', 1))
    require(example("inspect") == "CONFLICT", "unexpected credential field was accepted")
    config.write_text("invalid = [\n")
    example("inventory", ok=False)
    select("read")
    example("inspect", ok=False)
    require(config.read_text() == "invalid = [\n", "invalid configuration was modified")
    keychain_home = root / "keychain-codex"
    keychain_home.mkdir()
    env["CODEX_HOME"] = str(keychain_home)
    for profile in ("read", "write"):
        select(profile, "keychain")
        example("add-keychain")
        require(example("inspect") == "MATCH", "keychain references differ from plan")
    require(not (home / ".codex/config.toml").exists(), "default CODEX_HOME was touched")
    require(not list(root.rglob("hooks.json")) and not list(root.rglob("capture-profile.json")),
            "connection setup activated capture")
    require(not (root / "unexpected-launch").exists(), "registration launched a provider entry point")
    version = run([codex, "--version"])
    print("PASS: documented connection commands; actual " + version +
          "; isolated HOME/CODEX_HOME/cwd; mock references; no providers")
PY
