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
        server_launcher = self.client / "bin" / "obsidian-mcp-server"
        server_launcher.write_text("#!/bin/sh\nexit 0\n")
        server_launcher.chmod(0o755)
        self.vault = self.root / "vault"
        self.vault.mkdir()
        self.env = dict(os.environ, HOME=str(self.home))
        self.env.pop("CLAUDE_CONFIG_DIR", None)

    def run_setup(self, *extra):
        return subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--endpoint", "https://vault.example/mcp", *extra],
            env=self.env, text=True, capture_output=True,
        )

    def run_vault_setup(self, *extra):
        return subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--vault", str(self.vault), *extra],
            env=self.env, text=True, capture_output=True,
        )

    def assertRefused(self, result, reason):
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn(reason, result.stderr)

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
        self.assertRefused(result, "invalid endpoint")
        self.assertNotIn("secret", result.stdout + result.stderr)

    def test_missing_launcher_and_empty_home_refuse(self):
        (self.client / "bin/obsidian-mcp-write").unlink()
        self.assertRefused(self.run_setup("--apply"), "install the verified public client")
        self.assertEqual(list(self.home.iterdir()), [])
        self.env["HOME"] = ""
        self.assertRefused(self.run_setup("--apply"), "HOME must be set and nonempty")

    def test_unknown_home_user_refuses_without_traceback(self):
        result = subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--vault", "~no-such-user-for-setup-test/vault", "--apply"],
            env=self.env, text=True, capture_output=True,
        )
        self.assertRefused(result, "configuration or prerequisites rejected")
        self.assertNotIn("Traceback", result.stderr)

    def test_vault_dry_run_and_apply(self):
        result = self.run_vault_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])
        plan = json.loads(result.stdout)
        self.assertFalse(plan["applied"])
        self.assertEqual(plan["capture_writer"], "unchanged")

        result = self.run_vault_setup("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads((self.home / ".claude.json").read_text())
        settings = json.loads((self.home / ".claude/settings.json").read_text())

        read_server = config["mcpServers"]["obsidian"]
        self.assertEqual(read_server["command"], str(self.client / "bin/obsidian-mcp-server"))
        self.assertEqual(read_server["args"], ["--vault", str(self.vault.resolve())])
        self.assertEqual(read_server["env"], {})

        write_server = config["mcpServers"]["obsidian-write"]
        self.assertEqual(write_server["command"], str(self.client / "bin/obsidian-mcp-server"))
        self.assertEqual(write_server["args"], ["--vault", str(self.vault.resolve())])
        self.assertEqual(write_server["env"], {"MCP_STDIO_PROFILE": "write"})

        self.assertEqual(
            settings["permissions"]["allow"],
            ["mcp__obsidian-write__obsidian_keeper_save", "mcp__obsidian-write__obsidian_daily_append"],
        )

        result = self.run_vault_setup("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["changed_files"], 0)

    def test_vault_with_daily_path_and_repo_roots(self):
        repo1 = self.root / "repo1"
        repo2 = self.root / "repo2"
        repo1.mkdir()
        repo2.mkdir()

        result = self.run_vault_setup(
            "--daily-path", "Journal/Daily",
            "--repo-root", str(repo1),
            "--repo-root", str(repo2),
            "--apply",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads((self.home / ".claude.json").read_text())
        expected_args = [
            "--vault", str(self.vault.resolve()),
            "--daily-path", "Journal/Daily",
            "--repo-root", str(repo1.resolve()),
            "--repo-root", str(repo2.resolve()),
        ]
        self.assertEqual(config["mcpServers"]["obsidian"]["args"], expected_args)
        self.assertEqual(config["mcpServers"]["obsidian-write"]["args"], expected_args)
        self.assertEqual(config["mcpServers"]["obsidian"]["env"], {})
        self.assertEqual(config["mcpServers"]["obsidian-write"]["env"], {"MCP_STDIO_PROFILE": "write"})

    def test_mutually_exclusive_endpoint_and_vault(self):
        result = subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--endpoint", "https://vault.example/mcp",
             "--vault", str(self.vault), "--apply"],
            env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("not allowed with argument", result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_usage_errors_name_the_rejected_argument(self):
        result = self.run_vault_setup("--vualt", "x")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments: --vualt", result.stderr)

    def test_neither_endpoint_nor_vault_refuses(self):
        result = subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client), "--apply"],
            env=self.env, text=True, capture_output=True,
        )
        self.assertRefused(result, "either --endpoint or --vault is required")

    def test_endpoint_refuses_daily_path_and_repo_root(self):
        result = self.run_setup("--daily-path", "Daily", "--apply")
        self.assertRefused(result, "--daily-path and --repo-root require --vault")
        repo = self.root / "repo"
        repo.mkdir()
        result = self.run_setup("--repo-root", str(repo), "--apply")
        self.assertRefused(result, "--daily-path and --repo-root require --vault")

    def test_vault_refuses_endpoint_flags(self):
        token = self.root / "read-token"
        token.write_text("secret")
        token.chmod(0o600)
        result = self.run_vault_setup("--read-token-file", str(token), "--apply")
        self.assertRefused(result, "cannot be used with --vault")
        result = self.run_vault_setup("--allow-tailnet-http", "--apply")
        self.assertRefused(result, "cannot be used with --vault")

    def test_vault_nonexistent_or_file_refuses(self):
        nonexistent = self.root / "does-not-exist"
        result = subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--vault", str(nonexistent), "--apply"],
            env=self.env, text=True, capture_output=True,
        )
        self.assertRefused(result, "vault path must be an existing directory")

        regular_file = self.root / "file-not-dir"
        regular_file.write_text("file")
        result = subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--vault", str(regular_file), "--apply"],
            env=self.env, text=True, capture_output=True,
        )
        self.assertRefused(result, "vault path must be an existing directory")

    def test_vault_invalid_daily_path_refuses(self):
        result = self.run_vault_setup("--daily-path", "/absolute/daily", "--apply")
        self.assertRefused(result, "daily path must be relative to the vault")
        result = self.run_vault_setup("--daily-path", "../escaped", "--apply")
        self.assertRefused(result, "daily path must be relative to the vault")
        result = self.run_vault_setup("--daily-path", "daily\ninvalid", "--apply")
        self.assertRefused(result, "invalid daily path")

    def test_empty_daily_path_refuses(self):
        self.assertRefused(self.run_vault_setup("--daily-path", "", "--apply"), "invalid daily path")
        self.assertRefused(self.run_setup("--daily-path", "", "--apply"),
                           "--daily-path and --repo-root require --vault")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_control_characters_in_vault_or_repo_root_refuse(self):
        odd = self.root / "vault\ninjected: true"
        odd.mkdir()
        result = subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--vault", str(odd), "--apply"],
            env=self.env, text=True, capture_output=True,
        )
        self.assertRefused(result, "invalid vault path")
        self.assertRefused(self.run_vault_setup("--repo-root", str(odd), "--apply"),
                           "invalid repository root")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_relative_vault_and_repo_root_are_stored_absolute(self):
        (self.root / "repo").mkdir()
        result = subprocess.run(
            ["python3", str(SCRIPT), "--client-dir", str(self.client),
             "--vault", "vault", "--repo-root", "repo", "--apply"],
            cwd=self.root, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.home / ".claude.json").read_text())["mcpServers"]["obsidian"]["args"]
        self.assertEqual(args, ["--vault", str(self.vault.resolve()),
                                "--repo-root", str((self.root / "repo").resolve())])
        self.assertTrue(Path(args[1]).is_absolute())

    def test_empty_repo_root_refuses(self):
        self.assertRefused(self.run_vault_setup("--repo-root", "", "--apply"),
                           "repository root must be set and nonempty")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_vault_nonexistent_repo_root_refuses(self):
        nonexistent = self.root / "nonexistent-repo"
        result = self.run_vault_setup("--repo-root", str(nonexistent), "--apply")
        self.assertRefused(result, "repository root must be an existing directory")

    def test_vault_missing_server_launcher_refuses(self):
        (self.client / "bin/obsidian-mcp-server").unlink()
        result = self.run_vault_setup("--apply")
        self.assertRefused(result, "bin/obsidian-mcp-server requires client-v0.3.3 or later")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_vault_non_executable_server_launcher_refuses(self):
        (self.client / "bin/obsidian-mcp-server").chmod(0o644)
        result = self.run_vault_setup("--apply")
        self.assertRefused(result, "bin/obsidian-mcp-server requires client-v0.3.3 or later")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_vault_conflicting_registration_refuses(self):
        config = self.home / ".claude.json"
        original = json.dumps({"mcpServers": {"obsidian": {"command": "other-server"}}})
        config.write_text(original)
        result = self.run_vault_setup("--apply")
        self.assertRefused(result, "existing Obsidian registration differs")
        self.assertEqual(config.read_text(), original)


    def test_vault_conflict_on_write_server_alone_refuses(self):
        self.assertEqual(self.run_vault_setup("--apply").returncode, 0)
        config = self.home / ".claude.json"
        value = json.loads(config.read_text())
        value["mcpServers"]["obsidian-write"]["env"] = {}
        original = json.dumps(value)
        config.write_text(original)
        result = self.run_vault_setup("--apply")
        self.assertRefused(result, "existing Obsidian registration differs")
        self.assertEqual(config.read_text(), original)


if __name__ == "__main__":
    unittest.main()
