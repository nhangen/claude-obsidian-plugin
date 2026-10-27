import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "ownership_fixture", ROOT / "tests/capture-ownership.py"
)
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
INDEX = ROOT / "scripts/vault-index-apply"


class LibrarianOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FIXTURE.OwnershipTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.vault = self.fixture.vault
        (self.vault / "existing-note.md").write_text("A fixture note\n")

    def apply_index(self, inherited=False):
        self.assertTrue(INDEX.is_file(), "guarded client INDEX entry point is missing")
        command = [
            "bash",
            str(INDEX),
            str(self.vault),
            str(self.vault),
            str(self.vault / "INDEX.md"),
        ]
        if inherited:
            command = [sys.executable, str(FIXTURE.OWNER), "legacy", "--", *command]
        return subprocess.run(
            command, env=self.fixture.env, capture_output=True, text=True, timeout=10
        )

    def test_same_named_commands_read_physical_skill_instead_of_recursing(self):
        for name in ("ask", "setup", "recall"):
            with self.subTest(command=name):
                command = (ROOT / "commands" / (name + ".md")).read_text()
                skill = ROOT / "skills" / name / "SKILL.md"
                self.assertTrue(skill.is_file())
                self.assertIn("name: obsidian:" + name, command)
                self.assertIn("name: " + name, skill.read_text())
                self.assertIn(
                    "${CLAUDE_PLUGIN_ROOT}/skills/" + name + "/SKILL.md", command
                )
                self.assertNotIn("Dispatch the `vault-librarian`", command)

    def test_librarian_routes_owner_before_reading_local_vault_configuration(self):
        agent = (ROOT / "agents/vault-librarian.md").read_text()
        self.assertLess(
            agent.index("capture-owner.py"), agent.index("resolve-config.sh")
        )
        self.assertIn("stable MCP ownership", agent)
        self.assertIn("Disabled/draining", agent)
        self.assertEqual(
            agent.count(
                '/scripts/vault-index-apply" "$VAULT_PATH" "$FOLDER" "$FOLDER/INDEX.md"'
            ),
            2,
        )
        self.assertNotIn('$(vault_index_apply "$VAULT_PATH"', agent)

    def test_guarded_index_succeeds_for_stable_legacy_and_inherited_lease(self):
        for inherited in (False, True):
            with self.subTest(inherited=inherited):
                result = self.apply_index(inherited)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(
                    "[[existing-note]]", (self.vault / "INDEX.md").read_text()
                )
                self.assertTrue((self.vault / ".INDEX.state").is_file())

    def test_nonlegacy_index_refusal_never_creates_or_changes_vault_files(self):
        for owner, phase in (
            ("disabled", "stable"),
            ("mcp", "stable"),
            ("legacy", "draining"),
        ):
            for existing in (False, True):
                with self.subTest(owner=owner, phase=phase, existing=existing):
                    self.fixture.evidence(
                        "capture-ownership/owner.json",
                        dict(
                            schema=1,
                            owner=owner,
                            phase=phase,
                            generation=1,
                            profiles={},
                        ),
                    )
                    index = self.vault / "INDEX.md"
                    sidecar = self.vault / ".INDEX.state"
                    if existing:
                        index.write_text("Existing INDEX must stay unchanged\n")
                        sidecar.write_text("Existing state must stay unchanged\n")
                    else:
                        index.unlink(missing_ok=True)
                        sidecar.unlink(missing_ok=True)
                    before = {p.name: p.read_bytes() for p in self.vault.iterdir()}
                    result = self.apply_index()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("no local fallback", result.stderr)
                    self.assertEqual(
                        {p.name: p.read_bytes() for p in self.vault.iterdir()}, before
                    )

    def test_authoritative_server_index_is_not_disabled_by_client_ownership(self):
        selected = self.fixture.handoff()
        self.assertEqual(selected.returncode, 0, selected.stderr)
        body = self.fixture.case / "body.md"
        body.write_text("Authoritative server fixture\n")
        result = subprocess.run(
            [
                "bash",
                str(ROOT / "packages/mcp-server/helpers/keeper"),
                "insert",
                "--vault",
                str(self.vault),
                "--target",
                "Notes/server.md",
                "--body-file",
                str(body),
            ],
            env=self.fixture.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("server", (self.vault / "Notes/INDEX.md").read_text())
        owner = self.fixture.run_owner("status")
        self.assertEqual(json.loads(owner.stdout)["owner"], "disabled")

    def test_guarded_index_requires_exact_arguments(self):
        self.assertTrue(INDEX.is_file())
        result = subprocess.run(
            ["bash", str(INDEX), str(self.vault)],
            env=self.fixture.env,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main()
