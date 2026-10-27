import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/setup-mcp.py"


class SetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.client = self.root / "client"
        (self.client / "bin").mkdir(parents=True)
        for profile in ("read", "write"):
            launcher = self.client / "bin" / f"obsidian-mcp-{profile}"
            launcher.write_text("#!/bin/sh\nexit 0\n")
            launcher.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home))
        self.env.pop("CLAUDE_CONFIG_DIR", None)

    def run_setup(self, *extra):
        return subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--endpoint", "https://vault.example/mcp", *extra],
            env=self.env, text=True, capture_output=True,
        )

    def test_dry_run_writes_nothing_and_never_prints_token(self):
        self.env["OBSIDIAN_MCP_READ_TOKEN"] = "private-canary-secret"
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertNotIn("private-canary-secret", result.stdout + result.stderr)
        plan = json.loads(result.stdout)
        self.assertFalse(plan["applied"])
        self.assertEqual(plan["capture_writer"], "unchanged")

    def test_apply_preserves_other_settings_and_is_idempotent(self):
        config = self.home / ".claude.json"
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir()
        config.write_text(json.dumps({"other": True, "mcpServers": {"other": {"command": "other"}}}))
        settings.write_text(json.dumps({"hooks": {"Stop": []}, "permissions": {"allow": ["Read"]}}))
        result = self.run_setup("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        updated = json.loads(config.read_text())
        self.assertTrue(updated["other"])
        self.assertEqual(updated["mcpServers"]["other"], {"command": "other"})
        read = updated["mcpServers"]["obsidian"]
        self.assertEqual(read["command"], str(self.client / "bin/obsidian-mcp-read"))
        self.assertEqual(read["env"]["OBSIDIAN_MCP_READ_TOKEN_ENV"], "OBSIDIAN_MCP_READ_TOKEN")
        self.assertNotIn("OBSIDIAN_MCP_READ_TOKEN", read["env"])
        after = json.loads(settings.read_text())
        self.assertEqual(after["hooks"], {"Stop": []})
        self.assertEqual(after["permissions"]["allow"], ["Read", "mcp__obsidian-write__obsidian_keeper_save", "mcp__obsidian-write__obsidian_daily_append"])
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        before = (config.read_bytes(), settings.read_bytes(), sorted(self.home.rglob("*.bak.*")))
        result = self.run_setup("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, (config.read_bytes(), settings.read_bytes(), sorted(self.home.rglob("*.bak.*"))))

    def test_conflicting_registration_refuses_before_any_change(self):
        config = self.home / ".claude.json"
        original = json.dumps({"mcpServers": {"obsidian": {"command": "legacy"}}})
        config.write_text(original)
        result = self.run_setup("--apply")
        self.assertEqual(result.returncode, 64)
        self.assertEqual(config.read_text(), original)
        self.assertFalse((self.home / ".claude").exists())

    def test_invalid_settings_refuses_before_registration(self):
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir()
        settings.write_text('{"permissions":{"allow":"invalid"}}')
        self.assertEqual(self.run_setup("--apply").returncode, 64)
        self.assertFalse((self.home / ".claude.json").exists())

    def test_explicit_deny_or_ask_is_preserved_and_blocks_setup(self):
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir()
        for field in ("deny", "ask"):
            original = json.dumps({"permissions": {field: ["mcp__obsidian-write__*"]}})
            settings.write_text(original)
            self.assertEqual(self.run_setup("--apply").returncode, 64)
            self.assertEqual(settings.read_text(), original)
            self.assertFalse((self.home / ".claude.json").exists())

    def test_private_credential_files_are_referenced_not_copied(self):
        token = self.root / "read-token"
        token.write_text("secret-file-canary")
        token.chmod(0o644)
        self.assertEqual(self.run_setup("--read-token-file", str(token), "--apply").returncode, 64)
        token.chmod(0o600)
        result = self.run_setup("--read-token-file", str(token), "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = (self.home / ".claude.json").read_text()
        self.assertNotIn("secret-file-canary", config + result.stdout + result.stderr)
        env = json.loads(config)["mcpServers"]["obsidian"]["env"]
        self.assertEqual(env["OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER"], "file")
        self.assertEqual(env["OBSIDIAN_MCP_READ_TOKEN_FILE"], str(token))

    def test_partial_configuration_can_be_completed_without_duplicate_entries(self):
        result = self.run_setup("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.home / ".claude/settings.json").unlink()
        config_before = (self.home / ".claude.json").read_bytes()
        result = self.run_setup("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / ".claude.json").read_bytes(), config_before)
        self.assertEqual(json.loads(result.stdout)["changed_files"], 1)

    def test_symlink_refuses_without_touching_destination(self):
        victim = self.root / "victim"
        victim.write_text("{}")
        (self.home / ".claude.json").symlink_to(victim)
        self.assertEqual(self.run_setup("--apply").returncode, 64)
        self.assertEqual(victim.read_text(), "{}")

    def test_http_requires_explicit_transport_policy(self):
        self.assertEqual(self.run_setup("--endpoint", "http://100.100.1.2:3010/mcp").returncode, 64)
        result = self.run_setup("--endpoint", "http://100.100.1.2:3010/mcp", "--allow-tailnet-http", "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        env = json.loads((self.home / ".claude.json").read_text())["mcpServers"]["obsidian"]["env"]
        self.assertEqual(env["OBSIDIAN_MCP_ALLOW_HTTP"], "1")
        self.assertEqual(env["OBSIDIAN_MCP_ALLOW_TAILNET_HTTP"], "1")

    def test_endpoint_credentials_are_rejected_without_echo(self):
        result = self.run_setup("--endpoint", "https://secret@vault.example/mcp")
        self.assertEqual(result.returncode, 64)
        self.assertNotIn("secret", result.stdout + result.stderr)

    def test_missing_launcher_and_empty_home_refuse(self):
        (self.client / "bin/obsidian-mcp-write").unlink()
        self.assertEqual(self.run_setup("--apply").returncode, 64)
        self.assertEqual(list(self.home.iterdir()), [])
        self.env["HOME"] = ""
        self.assertEqual(self.run_setup("--apply").returncode, 64)


if __name__ == "__main__":
    unittest.main()
