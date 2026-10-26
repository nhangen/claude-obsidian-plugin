#!/usr/bin/env python3

from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import hashlib
import io
import json
import os
import pathlib
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from collections.abc import Callable
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
PACK = ROOT / "scripts/pack-obsidian-mcp-client.py"


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_installer(path: pathlib.Path):
    # Avoid bytecode artifacts inside the authenticated bundle under test.
    module = types.ModuleType("installer_under_test")
    module.__file__ = str(path)
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    return module


class ClientLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="obsidian-client-lifecycle-"
        )
        self.root = pathlib.Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.prefix = self.home / ".local/share/obsidian-mcp-client"
        self.bundle_a = self.pack("a")
        catalog = json.loads((ROOT / "packages/client/catalog.json").read_text())
        catalog["release"]["tag"] = "mcp-v0.2.0-test-b"
        catalog["release"]["sourceCommit"] = "b" * 40
        catalog["contract"]["commit"] = "b" * 40
        catalog_path = self.root / "catalog-b.json"
        catalog_path.write_text(json.dumps(catalog) + "\n")
        self.bundle_b = self.pack("b", catalog_path)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def pack(self, name: str, catalog: pathlib.Path | None = None) -> pathlib.Path:
        output = self.root / f"bundle-{name}"
        command = [sys.executable, str(PACK), "--output", str(output)]
        if catalog is not None:
            command.extend(["--catalog", str(catalog)])
        subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
        return output

    def installer(self, bundle: pathlib.Path) -> pathlib.Path:
        return bundle / "bin/obsidian-mcp-client-install"

    def run_installer(
        self,
        bundle: pathlib.Path,
        *arguments: str,
        expected: str | None = None,
        check: bool = True,
        environment: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(self.installer(bundle)),
            "--prefix",
            str(self.prefix),
        ]
        if expected is not None:
            command.extend(["--release-sha256", expected])
        command.extend(arguments)
        env = {
            "HOME": str(self.home),
            "PATH": "/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        if environment:
            env.update(environment)
        return subprocess.run(
            command,
            check=check,
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout,
        )

    def install(self, bundle: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return self.run_installer(
            bundle, "--bundle", str(bundle), expected=sha256(bundle / "release.json")
        )

    def slots(self) -> dict[str, str | None]:
        result: dict[str, str | None] = {}
        for name in ("current", "previous", "disabled"):
            path = self.prefix / name
            result[name] = (
                os.readlink(path).split("/")[-1] if path.is_symlink() else None
            )
        return result

    def release_id(self, bundle: pathlib.Path) -> str:
        return json.loads((bundle / "release.json").read_text())["releaseId"]

    def copy_bundle(self, name: str) -> pathlib.Path:
        target = self.root / name
        shutil.copytree(self.bundle_a, target)
        return target

    def assert_rejected_without_slots(
        self, bundle: pathlib.Path, expected: str, message: str
    ) -> None:
        result = self.run_installer(
            bundle,
            "--bundle",
            str(bundle),
            expected=expected,
            check=False,
        )
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn(message, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.prefix.exists())

    def test_dry_run_install_reinstall_upgrade_disable_enable_and_rollback(
        self,
    ) -> None:
        digest_a = sha256(self.bundle_a / "release.json")
        release_a = self.release_id(self.bundle_a)
        dry = self.run_installer(
            self.bundle_a,
            "--bundle",
            str(self.bundle_a),
            "--dry-run",
            expected=digest_a,
        )
        self.assertEqual(
            json.loads(dry.stdout),
            {
                "after": {
                    "current": release_a,
                    "previous": None,
                    "disabled": None,
                },
                "before": {
                    "current": None,
                    "previous": None,
                    "disabled": None,
                },
                "dryRun": True,
                "operation": "install",
            },
        )
        self.assertFalse(self.prefix.exists())

        first = self.install(self.bundle_a)
        self.assertEqual(
            self.slots(), {"current": release_a, "previous": None, "disabled": None}
        )
        release_path = self.prefix / "releases" / release_a
        inode = release_path.stat().st_ino
        reinstall = self.install(self.bundle_a)
        self.assertIn("already installed", reinstall.stdout)
        self.assertEqual(release_path.stat().st_ino, inode)
        self.assertEqual(first.stderr, "")

        self.install(self.bundle_b)
        release_b = self.release_id(self.bundle_b)
        self.assertEqual(
            self.slots(),
            {"current": release_b, "previous": release_a, "disabled": None},
        )
        self.run_installer(self.bundle_b, "--disable")
        self.assertEqual(
            self.slots(),
            {"current": None, "previous": release_a, "disabled": release_b},
        )
        self.run_installer(self.bundle_b, "--rollback")
        self.assertEqual(
            self.slots(),
            {"current": None, "previous": release_b, "disabled": release_a},
        )
        self.run_installer(self.bundle_b, "--enable")
        self.assertEqual(
            self.slots(),
            {"current": release_a, "previous": release_b, "disabled": None},
        )
        self.run_installer(self.bundle_b, "--rollback")
        self.assertEqual(
            self.slots(),
            {"current": release_b, "previous": release_a, "disabled": None},
        )
        self.assertTrue((self.prefix / "releases" / release_a).is_dir())
        self.assertTrue((self.prefix / "releases" / release_b).is_dir())

    def test_disabled_upgrade_stays_disabled(self) -> None:
        self.install(self.bundle_a)
        self.run_installer(self.bundle_a, "--disable")
        self.install(self.bundle_b)
        self.assertEqual(
            self.slots(),
            {
                "current": None,
                "previous": self.release_id(self.bundle_a),
                "disabled": self.release_id(self.bundle_b),
            },
        )

    def test_external_digest_is_checked_before_metadata_parse(self) -> None:
        bundle = self.copy_bundle("rewritten-metadata")
        metadata = bundle / "release.json"
        original = sha256(metadata)
        metadata.write_bytes(b"{malformed")
        result = self.run_installer(
            bundle,
            "--bundle",
            str(bundle),
            expected=original,
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("release metadata digest mismatch", result.stderr)
        self.assertFalse(self.prefix.exists())

        invalid = self.run_installer(
            self.bundle_a,
            "--bundle",
            str(self.root / "missing"),
            expected="A" * 64,
            check=False,
        )
        self.assertEqual(invalid.returncode, 64)
        self.assertIn("release digest is invalid", invalid.stderr)

    def test_installed_metadata_cannot_redefine_old_release_identity(self) -> None:
        self.install(self.bundle_a)
        release_id = self.release_id(self.bundle_a)
        release = self.prefix / "releases" / release_id
        payload = release / "README.md"
        payload.write_bytes(payload.read_bytes() + b"\ncoordinated tamper\n")
        metadata_path = release / "release.json"
        metadata = json.loads(metadata_path.read_text())
        for entry in metadata["files"]:
            if entry["path"] == "README.md":
                entry["sha256"] = sha256(payload)
                entry["size"] = payload.stat().st_size
        metadata_bytes = (
            json.dumps(metadata, indent=2, sort_keys=True) + "\n"
        ).encode()
        metadata_path.write_bytes(metadata_bytes)
        trust = {
            "externalReleaseJsonSha256": hashlib.sha256(metadata_bytes).hexdigest(),
            "formatVersion": 1,
            "releaseId": release_id,
        }
        (release / ".trust.json").write_bytes(
            json.dumps(trust, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        )
        result = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn("content inventory", result.stderr)
        self.assertEqual(
            self.slots(), {"current": release_id, "previous": None, "disabled": None}
        )

    def test_reinstall_requires_the_original_external_release_json_digest(
        self,
    ) -> None:
        self.install(self.bundle_a)
        release_id = self.release_id(self.bundle_a)
        trust_path = self.prefix / "releases" / release_id / ".trust.json"
        trust = json.loads(trust_path.read_text())
        trust["externalReleaseJsonSha256"] = "0" * 64
        trust_path.write_bytes(
            json.dumps(trust, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        )
        result = self.run_installer(
            self.bundle_a,
            "--bundle",
            str(self.bundle_a),
            expected=sha256(self.bundle_a / "release.json"),
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("release metadata digest mismatch", result.stderr)
        self.assertEqual(
            self.slots(), {"current": release_id, "previous": None, "disabled": None}
        )

    def test_release_json_digest_field_is_emitted_and_legacy_name_is_rejected(
        self,
    ) -> None:
        self.install(self.bundle_a)
        release_a = self.release_id(self.bundle_a)
        trust_path = self.prefix / "releases" / release_a / ".trust.json"
        trust = json.loads(trust_path.read_text())
        self.assertEqual(
            set(trust),
            {"externalReleaseJsonSha256", "formatVersion", "releaseId"},
        )
        self.assertEqual(
            trust["externalReleaseJsonSha256"],
            sha256(self.bundle_a / "release.json"),
        )
        trust_bytes = trust_path.read_bytes()
        legacy_trust = dict(trust)
        legacy_trust["externalManifestSha256"] = legacy_trust.pop(
            "externalReleaseJsonSha256"
        )
        trust_path.write_text(
            json.dumps(legacy_trust, sort_keys=True, separators=(",", ":")) + "\n"
        )
        before = self.slots()
        rejected_trust = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(rejected_trust.returncode, 64)
        self.assertIn("installed trust record schema is invalid", rejected_trust.stderr)
        self.assertEqual(self.slots(), before)
        trust_path.write_bytes(trust_bytes)

        failed = self.run_installer(
            self.bundle_b,
            "--bundle",
            str(self.bundle_b),
            expected=sha256(self.bundle_b / "release.json"),
            check=False,
            environment={
                "OBSIDIAN_MCP_CLIENT_TEST_ROOT": str(self.root),
                "OBSIDIAN_MCP_CLIENT_TEST_FAIL_AFTER": "intent_persisted",
            },
        )
        self.assertEqual(failed.returncode, 86, failed.stderr)
        journal_path = self.prefix / ".transition.json"
        journal = json.loads(journal_path.read_text())
        self.assertIn("externalReleaseJsonSha256", journal)
        self.assertNotIn("externalManifestSha256", journal)
        self.assertEqual(
            journal["externalReleaseJsonSha256"],
            sha256(self.bundle_b / "release.json"),
        )

        journal["externalManifestSha256"] = journal.pop("externalReleaseJsonSha256")
        journal_path.write_text(
            json.dumps(journal, sort_keys=True, separators=(",", ":")) + "\n"
        )
        before = self.slots()
        result = self.run_installer(
            self.bundle_b,
            "--bundle",
            str(self.bundle_b),
            expected=sha256(self.bundle_b / "release.json"),
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("transition journal schema is invalid", result.stderr)
        self.assertEqual(self.slots(), before)
        self.assertTrue(journal_path.exists())

    def test_source_root_symlink_is_rejected(self) -> None:
        alias = self.root / "bundle-alias"
        alias.symlink_to(self.bundle_a, target_is_directory=True)
        aliased = self.run_installer(
            self.bundle_a,
            "--bundle",
            str(alias),
            expected=sha256(self.bundle_a / "release.json"),
            check=False,
        )
        self.assertEqual(aliased.returncode, 64)
        self.assertIn("bundle must be a real directory", aliased.stderr)
        self.assertFalse(self.prefix.exists())

    def test_source_with_user_controlled_symlink_ancestor_is_rejected(self) -> None:
        real_parent = self.root / "real-source"
        bundle = real_parent / "bundle"
        shutil.copytree(self.bundle_a, bundle)
        alias_parent = self.root / "source-alias"
        alias_parent.symlink_to(real_parent, target_is_directory=True)
        aliased_bundle = alias_parent / "bundle"
        result = self.run_installer(
            self.bundle_a,
            "--bundle",
            str(aliased_bundle),
            expected=sha256(bundle / "release.json"),
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("unsafe ancestor", result.stderr)
        self.assertFalse(self.prefix.exists())

    def test_root_owned_temporary_alias_does_not_reject_a_real_bundle(self) -> None:
        if not pathlib.Path("/tmp").is_symlink():
            self.skipTest("native /tmp root-owned symlink is not present")
        self.assertEqual(pathlib.Path("/tmp").lstat().st_uid, 0)
        with tempfile.TemporaryDirectory(
            prefix="obsidian-client-root-alias-", dir="/tmp"
        ) as directory:
            bundle = pathlib.Path(directory) / "bundle"
            shutil.copytree(self.bundle_a, bundle)
            installed = self.run_installer(
                bundle,
                "--bundle",
                str(bundle),
                expected=sha256(bundle / "release.json"),
            )
        self.assertEqual(installed.returncode, 0)
        self.assertEqual(self.slots()["current"], self.release_id(self.bundle_a))

    def test_root_alias_policy_requires_both_known_path_and_root_owner(self) -> None:
        installer = load_installer(self.installer(self.bundle_a))
        real_parent = self.root / "alias-target"
        real_parent.mkdir()
        bundle = real_parent / "bundle"
        shutil.copytree(self.bundle_a, bundle)
        alias = self.root / "known-alias"
        alias.symlink_to(real_parent, target_is_directory=True)
        real_lstat = pathlib.Path.lstat

        def alias_lstat(path, *args, **kwargs):
            item = real_lstat(path, *args, **kwargs)
            if path == alias:
                fields = list(item)
                fields[4] = owner
                return os.stat_result(fields)
            return item

        # Simulate only privileged ownership; the symlink and bundle are real.
        # This executes the alias branch even on Linux, without root mutations.
        system_aliases = installer.ROOT_ALIAS_PATHS.copy()
        with mock.patch.object(pathlib.Path, "lstat", alias_lstat):
            for known, owner, accepted in (
                (True, 0, True),
                (True, 1, False),
                (False, 0, False),
            ):
                with self.subTest(known=known, owner=owner):
                    installer.ROOT_ALIAS_PATHS = system_aliases | (
                        {alias} if known else set()
                    )
                    if accepted:
                        identity = installer.source_identity(alias / "bundle")
                        item = bundle.stat()
                        self.assertEqual(identity, (item.st_dev, item.st_ino))
                    else:
                        with self.assertRaisesRegex(
                            installer.InstallError, "unsafe ancestor"
                        ):
                            installer.source_identity(alias / "bundle")

    def test_fifo_metadata_is_rejected_without_hanging(self) -> None:
        bundle = self.copy_bundle("fifo-metadata")
        metadata = bundle / "release.json"
        expected = sha256(metadata)
        metadata.unlink()
        os.mkfifo(metadata)
        started = subprocess.run(
            [
                sys.executable,
                str(self.installer(self.bundle_a)),
                "--prefix",
                str(self.prefix),
                "--bundle",
                str(bundle),
                "--release-sha256",
                expected,
            ],
            env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(started.returncode, 64)
        self.assertIn("not a private regular file", started.stderr)

    def test_fifo_payload_and_installed_trust_are_rejected_without_hanging(
        self,
    ) -> None:
        bundle = self.copy_bundle("fifo-payload")
        payload = bundle / "README.md"
        payload.unlink()
        os.mkfifo(payload)
        result = self.run_installer(
            self.bundle_a,
            "--bundle",
            str(bundle),
            expected=sha256(bundle / "release.json"),
            check=False,
            timeout=2,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("bundle contains an unsafe entry: README.md", result.stderr)

        self.install(self.bundle_a)
        release = self.prefix / "releases" / self.release_id(self.bundle_a)
        trust = release / ".trust.json"
        trust.unlink()
        os.mkfifo(trust)
        result = subprocess.run(
            [
                sys.executable,
                str(self.installer(self.bundle_a)),
                "--prefix",
                str(self.prefix),
                "--disable",
            ],
            env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn(
            "installed trust record is not a private regular file", result.stderr
        )

    def test_inventory_rejects_oversized_payload_declaration(self) -> None:
        bundle = self.copy_bundle("oversized-entry")
        metadata_path = bundle / "release.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["files"][0]["size"] = 64 * 1024 * 1024 + 1
        metadata_path.write_text(json.dumps(metadata, sort_keys=True) + "\n")
        result = self.run_installer(
            self.bundle_a,
            "--bundle",
            str(bundle),
            expected=sha256(metadata_path),
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("invalid size", result.stderr)

    def test_inventory_rejects_total_size_over_the_bundle_limit(self) -> None:
        bundle = self.copy_bundle("oversized-total")
        metadata_path = bundle / "release.json"
        metadata = json.loads(metadata_path.read_text())
        for entry in metadata["files"][:3]:
            entry["size"] = 64 * 1024 * 1024
        metadata_path.write_text(json.dumps(metadata, sort_keys=True) + "\n")
        result = self.run_installer(
            bundle,
            "--bundle",
            str(bundle),
            expected=sha256(metadata_path),
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("exceeds the bundle size limit", result.stderr)
        self.assertFalse(self.prefix.exists())

    def test_release_metadata_over_the_size_limit_is_rejected(self) -> None:
        bundle = self.copy_bundle("oversized-metadata")
        metadata_path = bundle / "release.json"
        metadata_path.write_bytes(metadata_path.read_bytes() + b" " * (1024 * 1024))
        result = self.run_installer(
            bundle,
            "--bundle",
            str(bundle),
            expected=sha256(metadata_path),
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("exceeds the size limit", result.stderr)
        self.assertFalse(self.prefix.exists())

    def test_operations_invalid_for_the_current_state_fail_without_writes(
        self,
    ) -> None:
        for operation, message in (
            ("--disable", "already disabled or not installed"),
            ("--enable", "already enabled or not installed"),
            ("--rollback", "rollback requires an active and previous release"),
        ):
            with self.subTest(operation=operation, state="empty"):
                result = self.run_installer(self.bundle_a, operation, check=False)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.prefix.exists())

        self.prefix.mkdir(parents=True)
        result = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("already disabled or not installed", result.stderr)
        self.assertEqual(list(self.prefix.iterdir()), [])
        self.prefix.rmdir()

        self.install(self.bundle_a)
        before = self.slots()
        for operation, message in (
            ("--enable", "already enabled or not installed"),
            ("--rollback", "rollback requires an active and previous release"),
        ):
            with self.subTest(operation=operation, state="installed"):
                result = self.run_installer(self.bundle_a, operation, check=False)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.slots(), before)

        self.run_installer(self.bundle_a, "--disable")
        disabled = self.slots()
        result = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("already disabled or not installed", result.stderr)
        self.assertEqual(self.slots(), disabled)

    def test_dry_run_previews_each_operation_without_writing(self) -> None:
        self.install(self.bundle_a)
        self.install(self.bundle_b)
        before = self.slots()
        for operation in ("--disable", "--rollback"):
            with self.subTest(operation=operation):
                result = self.run_installer(self.bundle_b, operation, "--dry-run")
                emitted = json.loads(result.stdout)
                self.assertEqual(
                    set(emitted), {"after", "before", "dryRun", "operation"}
                )
                self.assertEqual(emitted["operation"], operation.lstrip("-"))
                self.assertIs(emitted["dryRun"], True)
                self.assertEqual(self.slots(), before)
        self.run_installer(self.bundle_b, "--disable")
        disabled = self.slots()
        result = self.run_installer(self.bundle_b, "--enable", "--dry-run")
        self.assertEqual(json.loads(result.stdout)["operation"], "enable")
        self.assertEqual(self.slots(), disabled)

    def inventory_snapshot(self) -> tuple[dict[str, str | None], list[tuple]]:
        return (
            self.slots(),
            sorted(
                (
                    str(path.relative_to(self.prefix)),
                    stat.S_IMODE(path.lstat().st_mode),
                    os.readlink(path)
                    if path.is_symlink()
                    else sha256(path)
                    if path.is_file()
                    else None,
                )
                for path in (self.prefix, *self.prefix.rglob("*"))
            ),
        )

    def dry_run_map(
        self,
        bundle: pathlib.Path,
        *arguments: str,
        expected: str | None = None,
    ) -> dict:
        result = self.run_installer(bundle, *arguments, "--dry-run", expected=expected)
        self.assertEqual(result.stderr, "", result.stderr)
        self.assertEqual(result.stdout.count("\n"), 1)
        payload = json.loads(result.stdout)
        self.assertEqual(
            result.stdout,
            json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
        )
        self.assertEqual(set(payload), {"after", "before", "dryRun", "operation"})
        self.assertIs(payload["dryRun"], True)
        return payload

    def test_dry_run_json_maps_are_exact_for_every_operation(self) -> None:
        digest_a = sha256(self.bundle_a / "release.json")
        digest_b = sha256(self.bundle_b / "release.json")
        release_a = self.release_id(self.bundle_a)
        release_b = self.release_id(self.bundle_b)

        self.assertEqual(
            self.dry_run_map(
                self.bundle_a, "--bundle", str(self.bundle_a), expected=digest_a
            ),
            {
                "after": {
                    "current": release_a,
                    "previous": None,
                    "disabled": None,
                },
                "before": {
                    "current": None,
                    "previous": None,
                    "disabled": None,
                },
                "dryRun": True,
                "operation": "install",
            },
        )
        self.assertFalse(self.prefix.exists())

        self.install(self.bundle_a)
        inventory = self.inventory_snapshot()
        self.assertEqual(
            self.dry_run_map(
                self.bundle_a, "--bundle", str(self.bundle_a), expected=digest_a
            ),
            {
                "after": {
                    "current": release_a,
                    "previous": None,
                    "disabled": None,
                },
                "before": {
                    "current": release_a,
                    "previous": None,
                    "disabled": None,
                },
                "dryRun": True,
                "operation": "install",
            },
        )
        self.assertEqual(self.inventory_snapshot(), inventory)

        self.assertEqual(
            self.dry_run_map(
                self.bundle_b, "--bundle", str(self.bundle_b), expected=digest_b
            ),
            {
                "after": {
                    "current": release_b,
                    "previous": release_a,
                    "disabled": None,
                },
                "before": {
                    "current": release_a,
                    "previous": None,
                    "disabled": None,
                },
                "dryRun": True,
                "operation": "install",
            },
        )
        self.assertEqual(self.inventory_snapshot(), inventory)

        self.install(self.bundle_b)
        upgraded = self.slots()
        inventory = self.inventory_snapshot()
        self.assertEqual(
            self.dry_run_map(self.bundle_b, "--disable"),
            {
                "after": {
                    "current": None,
                    "previous": release_a,
                    "disabled": release_b,
                },
                "before": {
                    "current": release_b,
                    "previous": release_a,
                    "disabled": None,
                },
                "dryRun": True,
                "operation": "disable",
            },
        )
        self.assertEqual(self.inventory_snapshot(), inventory)

        self.run_installer(self.bundle_b, "--disable")
        inventory = self.inventory_snapshot()
        self.assertEqual(
            self.dry_run_map(self.bundle_b, "--enable"),
            {
                "after": {
                    "current": release_b,
                    "previous": release_a,
                    "disabled": None,
                },
                "before": {
                    "current": None,
                    "previous": release_a,
                    "disabled": release_b,
                },
                "dryRun": True,
                "operation": "enable",
            },
        )
        self.assertEqual(
            self.dry_run_map(self.bundle_b, "--rollback"),
            {
                "after": {
                    "current": None,
                    "previous": release_b,
                    "disabled": release_a,
                },
                "before": {
                    "current": None,
                    "previous": release_a,
                    "disabled": release_b,
                },
                "dryRun": True,
                "operation": "rollback",
            },
        )
        self.assertEqual(self.inventory_snapshot(), inventory)

        self.run_installer(self.bundle_b, "--enable")
        inventory = self.inventory_snapshot()
        self.assertEqual(
            self.dry_run_map(self.bundle_b, "--rollback"),
            {
                "after": {
                    "current": release_a,
                    "previous": release_b,
                    "disabled": None,
                },
                "before": {
                    "current": release_b,
                    "previous": release_a,
                    "disabled": None,
                },
                "dryRun": True,
                "operation": "rollback",
            },
        )
        self.assertEqual(self.inventory_snapshot(), inventory)
        self.assertEqual(self.slots(), upgraded)
        self.assertFalse((self.prefix / ".transition.json").exists())
        (self.prefix / ".install.lock").unlink()
        post_unlink = self.inventory_snapshot()
        self.dry_run_map(self.bundle_b, "--disable")
        self.assertFalse((self.prefix / ".install.lock").exists())
        self.assertFalse((self.prefix / ".transition.json").exists())
        self.assertEqual(self.inventory_snapshot(), post_unlink)

    def test_dry_run_cannot_proceed_while_recovery_is_required(self) -> None:
        release_a = self.release_id(self.bundle_a)
        release_b = self.release_id(self.bundle_b)
        self.install(self.bundle_a)
        journal_path = self.prefix / ".transition.json"
        journal_path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "operationId": "0" * 32,
                    "operation": "install",
                    "trustedReleaseId": release_b,
                    "externalReleaseJsonSha256": sha256(self.bundle_b / "release.json"),
                    "before": {
                        "current": release_a,
                        "previous": None,
                        "disabled": None,
                    },
                    "after": {
                        "current": release_b,
                        "previous": release_a,
                        "disabled": None,
                    },
                    "enabledState": "enabled",
                    "phase": "intent",
                    "steps": [
                        {
                            "current": release_a,
                            "previous": release_a,
                            "disabled": None,
                        },
                        {
                            "current": release_b,
                            "previous": release_a,
                            "disabled": None,
                        },
                    ],
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        )
        journal_path.chmod(0o600)
        result = self.run_installer(
            self.bundle_a, "--disable", "--dry-run", check=False
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("recovery is required", result.stderr)
        self.assertEqual(
            self.slots(),
            {"current": release_a, "previous": None, "disabled": None},
        )
        self.assertTrue(journal_path.exists())

    def test_dry_run_verifies_an_already_installed_release(self) -> None:
        self.install(self.bundle_a)
        reformatted = self.copy_bundle("reformatted-metadata")
        metadata_path = reformatted / "release.json"
        metadata = json.loads(metadata_path.read_text())
        metadata_path.write_text(json.dumps(metadata, separators=(",", ":")) + "\n")
        self.assertNotEqual(
            sha256(metadata_path), sha256(self.bundle_a / "release.json")
        )
        result = self.run_installer(
            reformatted,
            "--bundle",
            str(reformatted),
            "--dry-run",
            expected=sha256(metadata_path),
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("different release.json digest", result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_filesystem_errors_fail_with_a_message_not_a_traceback(self) -> None:
        parent = self.home / "readonly"
        parent.mkdir()
        parent.chmod(0o500)
        self.prefix = parent / "client"
        try:
            result = self.run_installer(
                self.bundle_a,
                "--bundle",
                str(self.bundle_a),
                expected=sha256(self.bundle_a / "release.json"),
                check=False,
            )
        finally:
            parent.chmod(0o700)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertTrue(result.stderr.startswith("obsidian-mcp-client: "))
        self.assertIn("Permission denied", result.stderr)
        self.assertIn(str(parent), result.stderr)

    def test_release_capture_defaults_must_be_literal_false(self) -> None:
        for name, value in (("zero", 0), ("null", None), ("omitted", "omitted")):
            with self.subTest(name=name):
                bundle = self.copy_bundle(f"capture-default-{name}")
                metadata_path = bundle / "release.json"
                metadata = json.loads(metadata_path.read_text())
                if value == "omitted":
                    del metadata["captureDefaults"]["defaultActivated"]
                else:
                    metadata["captureDefaults"]["defaultActivated"] = value
                metadata_path.write_text(json.dumps(metadata, sort_keys=True) + "\n")
                result = self.run_installer(
                    self.bundle_a,
                    "--bundle",
                    str(bundle),
                    expected=sha256(metadata_path),
                    check=False,
                )
                self.assertEqual(result.returncode, 64)
                self.assertIn("capture defaults", result.stderr)
                self.assertFalse(self.prefix.exists())

    def test_payload_mutations_fail_before_activation(self) -> None:
        cases: list[tuple[str, Callable[[pathlib.Path], object], str]] = [
            (
                "bytes",
                lambda bundle: (bundle / "README.md").write_bytes(b"changed\n"),
                "bundle file README.md size mismatch",
            ),
            (
                "mode",
                lambda bundle: (bundle / "README.md").chmod(0o600),
                "bundle file README.md has an unsafe mode",
            ),
            (
                "extra",
                lambda bundle: (bundle / "extra").write_text("extra\n"),
                "bundle inventory does not match release metadata",
            ),
            (
                "missing",
                lambda bundle: (bundle / "README.md").unlink(),
                "bundle inventory does not match release metadata",
            ),
            (
                "symlink",
                self.make_symlink,
                "bundle contains an unsafe entry: README.md",
            ),
            ("hardlink", self.make_hardlink, "bundle contains a hard-linked file:"),
            ("special", self.make_fifo, "bundle contains an unsafe entry: README.md"),
        ]
        for name, mutate, message in cases:
            with self.subTest(name=name):
                bundle = self.copy_bundle(f"mutation-{name}")
                expected = sha256(bundle / "release.json")
                mutate(bundle)
                self.assert_rejected_without_slots(bundle, expected, message)

    @staticmethod
    def make_symlink(bundle: pathlib.Path) -> None:
        path = bundle / "README.md"
        path.unlink()
        path.symlink_to("manifest.json")

    @staticmethod
    def make_hardlink(bundle: pathlib.Path) -> None:
        path = bundle / "README.md"
        path.unlink()
        os.link(bundle / "manifest.json", path)

    @staticmethod
    def make_fifo(bundle: pathlib.Path) -> None:
        path = bundle / "README.md"
        path.unlink()
        os.mkfifo(path)

    def test_untrusted_inventory_paths_are_rejected(self) -> None:
        for name, path in (("traversal", "../escape"), ("case", "README.MD")):
            with self.subTest(name=name):
                bundle = self.copy_bundle(f"inventory-{name}")
                metadata_path = bundle / "release.json"
                metadata = json.loads(metadata_path.read_text())
                entry = dict(metadata["files"][0])
                entry["path"] = path
                metadata["files"].append(entry)
                metadata_path.write_text(
                    json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n"
                )
                message = (
                    "unsafe path" if name == "traversal" else "case-colliding paths"
                )
                self.assert_rejected_without_slots(
                    bundle, sha256(metadata_path), message
                )

    def test_managed_symlink_and_slot_edges_fail_closed(self) -> None:
        unsafe_parent = self.root / "unsafe-parent"
        unsafe_parent.symlink_to(self.root / "elsewhere", target_is_directory=True)
        unsafe_prefix = unsafe_parent / "client"
        result = subprocess.run(
            [
                sys.executable,
                str(self.installer(self.bundle_a)),
                "--prefix",
                str(unsafe_prefix),
                "--bundle",
                str(self.bundle_a),
                "--release-sha256",
                sha256(self.bundle_a / "release.json"),
            ],
            env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("managed prefix contains an unsafe ancestor", result.stderr)

        self.install(self.bundle_a)
        current = self.prefix / "current"
        current.unlink()
        current.write_text("not a slot\n")
        rejected = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(rejected.returncode, 64)
        self.assertIn("managed slot is not a symlink: current", rejected.stderr)
        self.assertTrue(current.is_file())

    def test_broad_prefixes_fail_before_any_managed_write(self) -> None:
        filesystem_root = pathlib.Path(self.home.anchor)
        normalized_home_alias = self.home / "unused" / ".."
        for prefix in (self.home, normalized_home_alias, filesystem_root):
            with self.subTest(prefix=str(prefix)):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(self.installer(self.bundle_a)),
                        "--prefix",
                        str(prefix),
                        "--bundle",
                        str(self.bundle_a),
                        "--release-sha256",
                        sha256(self.bundle_a / "release.json"),
                    ],
                    env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 64)
                self.assertIn("managed prefix is too broad", result.stderr)
        self.assertFalse((self.home / "releases").exists())
        self.assertFalse((self.home / ".install.lock").exists())

    def test_install_preserves_legacy_read_bridge_directory(self) -> None:
        legacy = self.prefix / "read-bridge-v1"
        legacy.mkdir(parents=True)
        marker = legacy / "marker"
        marker.write_text("preserve\n")
        self.install(self.bundle_a)
        self.assertEqual(marker.read_text(), "preserve\n")

    def test_completed_slot_maps_reject_duplicates_and_previous_without_active(
        self,
    ) -> None:
        for name in ("duplicate", "no-active"):
            with self.subTest(name=name):
                if self.prefix.exists():
                    shutil.rmtree(self.prefix)
                self.install(self.bundle_a)
                current = self.prefix / "current"
                previous = self.prefix / "previous"
                if name == "duplicate":
                    previous.symlink_to(os.readlink(current))
                else:
                    current.unlink()
                    previous.symlink_to("releases/" + self.release_id(self.bundle_a))
                result = self.run_installer(self.bundle_a, "--disable", check=False)
                self.assertEqual(result.returncode, 64)
                message = (
                    "selected and previous slots must be distinct"
                    if name == "duplicate"
                    else "previous slot requires a selected release"
                )
                self.assertIn(message, result.stderr)

    def test_unsafe_release_trust_and_slot_targets_fail_closed(self) -> None:
        cases = ("release", "trust", "target")
        for name in cases:
            with self.subTest(name=name):
                if self.prefix.exists():
                    shutil.rmtree(self.prefix)
                self.install(self.bundle_a)
                release_id = self.release_id(self.bundle_a)
                release = self.prefix / "releases" / release_id
                if name == "release":
                    moved = self.root / "moved-release"
                    if moved.exists():
                        shutil.rmtree(moved)
                    release.rename(moved)
                    release.symlink_to(moved, target_is_directory=True)
                elif name == "trust":
                    trust = release / ".trust.json"
                    saved = self.root / "saved-trust"
                    saved.write_bytes(trust.read_bytes())
                    trust.unlink()
                    trust.symlink_to(saved)
                else:
                    current = self.prefix / "current"
                    current.unlink()
                    current.symlink_to("../outside")
                result = self.run_installer(self.bundle_a, "--disable", check=False)
                self.assertEqual(result.returncode, 64)
                messages = {
                    "release": "managed release is missing or unsafe",
                    "trust": "cannot read installed trust record",
                    "target": "managed slot target is unsafe: current",
                }
                self.assertIn(messages[name], result.stderr)

    def lifecycle_arguments(self, bundle: pathlib.Path) -> argparse.Namespace:
        return argparse.Namespace(
            prefix=self.prefix,
            bundle=bundle,
            release_sha256=sha256(bundle / "release.json"),
            operation=None,
            dry_run=False,
        )

    def test_relative_prefix_is_normalized_before_validation(self) -> None:
        command = [
            sys.executable,
            str(self.installer(self.bundle_a)),
            "--prefix",
            "home/unused/../.local/share/obsidian-mcp-client",
            "--bundle",
            str(self.bundle_a),
            "--release-sha256",
            sha256(self.bundle_a / "release.json"),
        ]
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin"}
        preview = subprocess.run(
            command + ["--dry-run"],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(
            json.loads(preview.stdout)["after"]["current"],
            self.release_id(self.bundle_a),
        )
        self.assertFalse(self.prefix.exists())
        subprocess.run(command, cwd=self.root, env=env, capture_output=True, check=True)
        self.assertEqual(self.slots()["current"], self.release_id(self.bundle_a))
        self.assertFalse((self.home / "unused").exists())

    def test_client_owned_argument_failures_share_exit_code_64(self) -> None:
        commands = [
            [sys.executable, str(PACK)],
            [sys.executable, str(PACK), "--not-an-option"],
            [sys.executable, str(self.installer(self.bundle_a))],
            [sys.executable, str(self.installer(self.bundle_a)), "--not-an-option"],
        ]
        for name in ("obsidian-mcp-commit-event", "obsidian-mcp-capture-commit"):
            commands.append(
                [sys.executable, str(self.bundle_a / "bin" / name), "--not-an-option"]
            )
        for command in commands:
            with self.subTest(command=command):
                result = subprocess.run(
                    command,
                    input="",
                    capture_output=True,
                    text=True,
                    env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                )
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr)
                self.assertNotIn("Traceback", result.stderr)
        for script in (PACK, self.installer(self.bundle_a)):
            result = subprocess.run(
                [sys.executable, str(script), "--help"], capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("usage:", result.stdout)

    def test_release_copy_crashes_cannot_activate_partial_content(self) -> None:
        release_a = self.release_id(self.bundle_a)
        release_b = self.release_id(self.bundle_b)
        for checkpoint in (
            "release_payload_copied",
            "release_staged",
            "release_persisted",
        ):
            with self.subTest(checkpoint=checkpoint):
                if self.prefix.exists():
                    shutil.rmtree(self.prefix)
                self.install(self.bundle_a)
                before = self.slots()
                failed = self.run_installer(
                    self.bundle_b,
                    "--bundle",
                    str(self.bundle_b),
                    expected=sha256(self.bundle_b / "release.json"),
                    check=False,
                    environment={
                        "OBSIDIAN_MCP_CLIENT_TEST_ROOT": str(self.root),
                        "OBSIDIAN_MCP_CLIENT_TEST_FAIL_AFTER": checkpoint,
                    },
                )
                self.assertEqual(failed.returncode, 86, failed.stderr)
                self.assertEqual(self.slots(), before)
                self.assertFalse((self.prefix / ".transition.json").exists())
                destination = self.prefix / "releases" / release_b
                staging = list(self.prefix.glob(".release-*"))
                if checkpoint == "release_persisted":
                    self.assertTrue((destination / ".trust.json").is_file())
                    self.assertEqual(staging, [])
                else:
                    self.assertFalse(destination.exists())
                    self.assertEqual(len(staging), 1)
                    self.assertTrue((staging[0] / "README.md").is_file())
                    self.assertEqual(
                        (staging[0] / ".trust.json").exists(),
                        checkpoint == "release_staged",
                    )
                self.install(self.bundle_b)
                self.assertEqual(
                    self.slots(),
                    {"current": release_b, "previous": release_a, "disabled": None},
                )
                self.assertEqual(list(self.prefix.glob(".release-*")), staging)
                self.assertFalse((self.prefix / ".transition.json").exists())

    def test_preexisting_partial_or_tampered_release_is_not_replaced(self) -> None:
        for name in ("partial", "tampered"):
            with self.subTest(name=name):
                if self.prefix.exists():
                    shutil.rmtree(self.prefix)
                self.install(self.bundle_a)
                release = self.prefix / "releases" / self.release_id(self.bundle_b)
                if name == "partial":
                    release.mkdir()
                    (release / "README.md").write_text("partial content")
                    message = "cannot read installed trust record"
                else:
                    failed = self.run_installer(
                        self.bundle_b,
                        "--bundle",
                        str(self.bundle_b),
                        expected=sha256(self.bundle_b / "release.json"),
                        check=False,
                        environment={
                            "OBSIDIAN_MCP_CLIENT_TEST_ROOT": str(self.root),
                            "OBSIDIAN_MCP_CLIENT_TEST_FAIL_AFTER": "release_persisted",
                        },
                    )
                    self.assertEqual(failed.returncode, 86, failed.stderr)
                    (release / "README.md").write_text("tampered content")
                    message = "bundle file README.md size mismatch"
                before = self.inventory_snapshot()
                result = self.run_installer(
                    self.bundle_b,
                    "--bundle",
                    str(self.bundle_b),
                    expected=sha256(self.bundle_b / "release.json"),
                    check=False,
                )
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.inventory_snapshot(), before)
                self.assertFalse((self.prefix / ".transition.json").exists())

    def test_copy_rehashes_payload_changed_after_source_verification(self) -> None:
        self.install(self.bundle_a)
        before = self.inventory_snapshot()
        installer = load_installer(self.installer(self.bundle_b))
        real_verify = installer.verify_source
        verified = []

        def change_after_verification(bundle, expected_digest):
            result = real_verify(bundle, expected_digest)
            payload = bundle / "README.md"
            data = payload.read_bytes()
            payload.write_bytes(bytes([data[0] ^ 1]) + data[1:])
            verified.append(True)
            return result

        with (
            mock.patch.object(installer, "verify_source", change_after_verification),
            mock.patch.dict(os.environ, {"HOME": str(self.home)}),
        ):
            with self.assertRaisesRegex(
                installer.InstallError, "bundle file README.md digest mismatch"
            ):
                installer.lifecycle(self.lifecycle_arguments(self.bundle_b))
        self.assertEqual(verified, [True])
        self.assertEqual(self.inventory_snapshot(), before)
        self.assertFalse(
            (self.prefix / "releases" / self.release_id(self.bundle_b)).exists()
        )
        self.assertEqual(list(self.prefix.glob(".release-*")), [])

    def test_cleanup_failure_preserves_original_error_and_names_staging(self) -> None:
        self.install(self.bundle_a)
        before = self.slots()
        installer = load_installer(self.installer(self.bundle_b))
        diagnostics = io.StringIO()
        original_error = installer.InstallError("original payload copy failure")
        cleanup_error = PermissionError(errno.EACCES, "injected cleanup denial")
        with (
            mock.patch.object(installer, "copy_payload", side_effect=original_error),
            mock.patch.object(installer.shutil, "rmtree", side_effect=cleanup_error),
            mock.patch.dict(os.environ, {"HOME": str(self.home)}),
            contextlib.redirect_stderr(diagnostics),
        ):
            with self.assertRaises(installer.InstallError) as raised:
                installer.lifecycle(self.lifecycle_arguments(self.bundle_b))
        self.assertIs(raised.exception, original_error)
        staging = list(self.prefix.glob(".release-*"))
        self.assertEqual(len(staging), 1)
        self.assertIn(str(staging[0]), diagnostics.getvalue())
        self.assertIn("remove it manually before retrying", diagnostics.getvalue())
        self.assertEqual(self.slots(), before)
        self.assertFalse((self.prefix / ".transition.json").exists())

    def assert_cleanup_inspection_failure_preserves_original_error(
        self, *, suppress_exists_errors: bool
    ) -> None:
        self.install(self.bundle_a)
        before = self.inventory_snapshot()
        installer = load_installer(self.installer(self.bundle_b))
        diagnostics = io.StringIO()
        original_error = installer.InstallError("original payload copy failure")
        inspection_error = PermissionError(errno.EACCES, "injected inspection denial")
        real_stat = pathlib.Path.stat
        inspected = []
        copy_failed = False

        def fail_copy(*args, **kwargs):
            nonlocal copy_failed
            copy_failed = True
            raise original_error

        def fail_staging_stat(path, *args, **kwargs):
            if (
                copy_failed
                and path.parent == self.prefix
                and path.name.startswith(".release-")
            ):
                inspected.append(path)
                raise inspection_error
            return real_stat(path, *args, **kwargs)

        def exists_suppressing_os_errors(path, *args, **kwargs):
            # Model Python 3.14's documented exists behavior on older runtimes.
            try:
                path.stat(*args, **kwargs)
            except OSError:
                return False
            return True

        exists_context = (
            mock.patch.object(pathlib.Path, "exists", exists_suppressing_os_errors)
            if suppress_exists_errors
            else contextlib.nullcontext()
        )
        with (
            mock.patch.object(installer, "copy_payload", fail_copy),
            mock.patch.object(pathlib.Path, "stat", fail_staging_stat),
            exists_context,
            mock.patch.dict(os.environ, {"HOME": str(self.home)}),
            contextlib.redirect_stderr(diagnostics),
        ):
            with self.assertRaises(installer.InstallError) as raised:
                installer.lifecycle(self.lifecycle_arguments(self.bundle_b))
        self.assertIs(raised.exception, original_error)
        staging = list(self.prefix.glob(".release-*"))
        self.assertEqual(len(staging), 1)
        self.assertEqual(inspected, staging)
        self.assertEqual(
            diagnostics.getvalue(),
            f"obsidian-mcp-client: could not remove staging directory "
            f"{staging[0]}: {inspection_error}; remove it manually before retrying\n",
        )
        slots, entries = self.inventory_snapshot()
        self.assertEqual(
            (
                slots,
                [entry for entry in entries if not entry[0].startswith(".release-")],
            ),
            before,
        )
        self.assertFalse((self.prefix / ".transition.json").exists())

    def test_cleanup_inspection_failure_preserves_original_error(self) -> None:
        self.assert_cleanup_inspection_failure_preserves_original_error(
            suppress_exists_errors=False
        )

    def test_cleanup_inspection_failure_with_suppressed_exists_errors(self) -> None:
        self.assert_cleanup_inspection_failure_preserves_original_error(
            suppress_exists_errors=True
        )

    def test_cleanup_missing_staging_after_success_is_silent(self) -> None:
        result = self.install(self.bundle_a)
        self.assertEqual(result.stderr, "")
        self.assertEqual(self.slots()["current"], self.release_id(self.bundle_a))
        self.assertEqual(list(self.prefix.glob(".release-*")), [])
        self.assertFalse((self.prefix / ".transition.json").exists())

    def test_failure_seam_is_inert_without_its_test_root(self) -> None:
        for checkpoint in (
            "release_payload_copied",
            "release_staged",
            "release_persisted",
            "intent_persisted",
            "current_pointer_replaced",
        ):
            with self.subTest(checkpoint=checkpoint):
                if self.prefix.exists():
                    shutil.rmtree(self.prefix)
                result = self.run_installer(
                    self.bundle_a,
                    "--bundle",
                    str(self.bundle_a),
                    expected=sha256(self.bundle_a / "release.json"),
                    environment={"OBSIDIAN_MCP_CLIENT_TEST_FAIL_AFTER": checkpoint},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    self.slots()["current"], self.release_id(self.bundle_a)
                )
                self.assertFalse((self.prefix / ".transition.json").exists())

    def test_recovery_rejects_corrupt_phase_unknown_version_and_wrong_mode(
        self,
    ) -> None:
        self.install(self.bundle_a)
        failed = self.run_installer(
            self.bundle_b,
            "--bundle",
            str(self.bundle_b),
            expected=sha256(self.bundle_b / "release.json"),
            check=False,
            environment={
                "OBSIDIAN_MCP_CLIENT_TEST_ROOT": str(self.root),
                "OBSIDIAN_MCP_CLIENT_TEST_FAIL_AFTER": "intent_persisted",
            },
        )
        self.assertEqual(failed.returncode, 86, failed.stderr)
        path = self.prefix / ".transition.json"
        journal = json.loads(path.read_text())
        for key, value, mode, message in (
            ("phase", "corrupt", 0o600, "transition phase is invalid"),
            ("version", 2, 0o600, "transition journal schema is invalid"),
            ("phase", "intent", 0o644, "transition journal is unsafe"),
        ):
            with self.subTest(key=key, value=value, mode=mode):
                altered = dict(journal)
                altered[key] = value
                path.write_text(json.dumps(altered) + "\n")
                path.chmod(mode)
                before = self.inventory_snapshot()
                result = self.run_installer(self.bundle_b, "--disable", check=False)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.inventory_snapshot(), before)

    def test_state_changing_operations_wait_for_the_prefix_lock(self) -> None:
        self.install(self.bundle_a)
        install_command = [
            sys.executable,
            str(self.installer(self.bundle_a)),
            "--prefix",
            str(self.prefix),
            "--bundle",
            str(self.bundle_b),
            "--release-sha256",
            sha256(self.bundle_b / "release.json"),
        ]
        disable_command = [
            sys.executable,
            str(self.installer(self.bundle_a)),
            "--prefix",
            str(self.prefix),
            "--disable",
        ]
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin"}
        # The child signals only after a real nonblocking flock fails. A delayed
        # interpreter start cannot masquerade as a blocked installer anymore.
        bootstrap = """
import fcntl, os, runpy, sys
ready = int(sys.argv[1])
sys.argv = sys.argv[2:]
real_flock = fcntl.flock
def observed_flock(descriptor, operation):
    if operation == fcntl.LOCK_EX:
        try:
            real_flock(descriptor, operation | fcntl.LOCK_NB)
        except BlockingIOError:
            os.write(ready, b"waiting\\n")
        else:
            raise AssertionError("the parent-held lock was not contended")
    return real_flock(descriptor, operation)
fcntl.flock = observed_flock
runpy.run_path(sys.argv[0], run_name="__main__")
"""
        lock_descriptor = os.open(self.prefix / ".install.lock", os.O_RDWR)
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        children: list[subprocess.Popen[str]] = []
        readiness: list[int] = []
        try:
            for command in (install_command, disable_command):
                read_fd, write_fd = os.pipe()
                readiness.append(read_fd)
                try:
                    child = subprocess.Popen(
                        [sys.executable, "-c", bootstrap, str(write_fd), *command[1:]],
                        env=env,
                        pass_fds=(write_fd,),
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    children.append(child)
                finally:
                    os.close(write_fd)
            for descriptor in readiness:
                ready, _, _ = select.select([descriptor], [], [], 10)
                self.assertTrue(ready, "installer did not signal lock contention")
                self.assertEqual(os.read(descriptor, 64), b"waiting\n")
            self.assertTrue(all(child.poll() is None for child in children))
            self.assertEqual(
                self.slots(),
                {
                    "current": self.release_id(self.bundle_a),
                    "previous": None,
                    "disabled": None,
                },
            )
        finally:
            for descriptor in readiness:
                os.close(descriptor)
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
            os.close(lock_descriptor)
            results = []
            for child in children:
                try:
                    stdout, stderr = child.communicate(timeout=30)
                    results.append((stdout, stderr, child.returncode))
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate(timeout=10)
        self.assertTrue(all(result[2] == 0 for result in results), results)
        self.assertEqual(
            self.slots(),
            {
                "current": None,
                "previous": self.release_id(self.bundle_a),
                "disabled": self.release_id(self.bundle_b),
            },
        )

    def test_interrupted_upgrade_recovers_only_known_states(self) -> None:
        release_a = self.release_id(self.bundle_a)
        release_b = self.release_id(self.bundle_b)
        for checkpoint in (
            "intent_persisted",
            "before_previous_pointer_replace",
            "previous_pointer_replaced",
            "before_current_pointer_replace",
            "current_pointer_replaced",
        ):
            with self.subTest(checkpoint=checkpoint):
                if self.prefix.exists():
                    shutil.rmtree(self.prefix)
                self.install(self.bundle_a)
                failed = self.run_installer(
                    self.bundle_b,
                    "--bundle",
                    str(self.bundle_b),
                    expected=sha256(self.bundle_b / "release.json"),
                    check=False,
                    environment={
                        "OBSIDIAN_MCP_CLIENT_TEST_ROOT": str(self.root),
                        "OBSIDIAN_MCP_CLIENT_TEST_FAIL_AFTER": checkpoint,
                    },
                )
                self.assertEqual(failed.returncode, 86, failed.stderr)
                recovered = self.install(self.bundle_b)
                self.assertIn("installed", recovered.stdout)
                self.assertEqual(
                    self.slots(),
                    {"current": release_b, "previous": release_a, "disabled": None},
                )
                self.assertFalse((self.prefix / ".transition.json").exists())

    def test_mode_switch_and_disabled_rollback_recover_at_every_pointer(self) -> None:
        scenarios = {
            "disable": {
                "setup": lambda: self.install(self.bundle_a),
                "operation": "--disable",
                "checkpoints": (
                    "before_current_pointer_replace",
                    "current_pointer_replaced",
                    "before_disabled_pointer_replace",
                    "disabled_pointer_replaced",
                ),
                "recovery": self.bundle_a,
                "expected": lambda: {
                    "current": None,
                    "previous": None,
                    "disabled": self.release_id(self.bundle_a),
                },
            },
            "enable": {
                "setup": self.setup_disabled_a,
                "operation": "--enable",
                "checkpoints": (
                    "before_disabled_pointer_replace",
                    "disabled_pointer_replaced",
                    "before_current_pointer_replace",
                    "current_pointer_replaced",
                ),
                "recovery": self.bundle_a,
                "expected": lambda: {
                    "current": self.release_id(self.bundle_a),
                    "previous": None,
                    "disabled": None,
                },
            },
            "disabled-rollback": {
                "setup": self.setup_disabled_b_with_previous_a,
                "operation": "--rollback",
                "checkpoints": (
                    "before_previous_pointer_replace",
                    "previous_pointer_replaced",
                    "before_disabled_pointer_replace",
                    "disabled_pointer_replaced",
                ),
                "recovery": self.bundle_a,
                "expected": lambda: {
                    "current": None,
                    "previous": self.release_id(self.bundle_b),
                    "disabled": self.release_id(self.bundle_a),
                },
            },
        }
        for name, scenario in scenarios.items():
            for checkpoint in scenario["checkpoints"]:
                with self.subTest(scenario=name, checkpoint=checkpoint):
                    if self.prefix.exists():
                        shutil.rmtree(self.prefix)
                    scenario["setup"]()
                    failed = self.run_installer(
                        self.bundle_b,
                        scenario["operation"],
                        check=False,
                        environment={
                            "OBSIDIAN_MCP_CLIENT_TEST_ROOT": str(self.root),
                            "OBSIDIAN_MCP_CLIENT_TEST_FAIL_AFTER": checkpoint,
                        },
                    )
                    self.assertEqual(failed.returncode, 86, failed.stderr)
                    self.install(scenario["recovery"])
                    self.assertEqual(self.slots(), scenario["expected"]())
                    self.assertFalse((self.prefix / ".transition.json").exists())

    def setup_disabled_a(self) -> None:
        self.install(self.bundle_a)
        self.run_installer(self.bundle_a, "--disable")

    def setup_disabled_b_with_previous_a(self) -> None:
        self.install(self.bundle_a)
        self.install(self.bundle_b)
        self.run_installer(self.bundle_b, "--disable")

    def test_recovery_rejects_operation_and_after_state_mismatch(self) -> None:
        self.install(self.bundle_a)
        self.install(self.bundle_b)
        release_a = self.release_id(self.bundle_a)
        release_b = self.release_id(self.bundle_b)
        before = {"current": release_b, "previous": release_a, "disabled": None}
        journal = {
            "version": 1,
            "operationId": "0" * 32,
            "operation": "disable",
            "trustedReleaseId": release_a,
            "externalReleaseJsonSha256": sha256(self.bundle_a / "release.json"),
            "before": before,
            "after": {"current": release_a, "previous": release_b, "disabled": None},
            "enabledState": "enabled",
            "phase": "intent",
            "steps": [
                {"current": release_b, "previous": release_b, "disabled": None},
                {"current": release_a, "previous": release_b, "disabled": None},
            ],
        }
        path = self.prefix / ".transition.json"
        path.write_text(json.dumps(journal) + "\n")
        path.chmod(0o600)
        result = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn("semantics", result.stderr)
        self.assertEqual(self.slots(), before)
        self.assertTrue(path.exists())

    def test_recovery_rejects_a_noop_journal_that_production_cannot_emit(
        self,
    ) -> None:
        self.install(self.bundle_a)
        release_a = self.release_id(self.bundle_a)
        before = {"current": release_a, "previous": None, "disabled": None}
        journal = {
            "version": 1,
            "operationId": "0" * 32,
            "operation": "install",
            "trustedReleaseId": release_a,
            "externalReleaseJsonSha256": sha256(self.bundle_a / "release.json"),
            "before": before,
            "after": before,
            "enabledState": "enabled",
            "phase": "intent",
            "steps": [],
        }
        path = self.prefix / ".transition.json"
        path.write_text(json.dumps(journal) + "\n")
        path.chmod(0o600)
        result = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn("does not describe a state change", result.stderr)
        self.assertEqual(self.slots(), before)
        self.assertTrue(path.exists())

    def test_recovery_verifies_every_referenced_release_before_mutation(self) -> None:
        self.install(self.bundle_a)
        self.install(self.bundle_b)
        self.run_installer(self.bundle_b, "--rollback")
        release_a = self.release_id(self.bundle_a)
        release_b = self.release_id(self.bundle_b)
        (self.prefix / "previous").unlink()
        before = {"current": release_a, "previous": None, "disabled": None}
        journal = {
            "version": 1,
            "operationId": "0" * 32,
            "operation": "install",
            "trustedReleaseId": release_b,
            "externalReleaseJsonSha256": sha256(self.bundle_b / "release.json"),
            "before": before,
            "after": {"current": release_b, "previous": release_a, "disabled": None},
            "enabledState": "enabled",
            "phase": "intent",
            "steps": [
                {"current": release_a, "previous": release_a, "disabled": None},
                {"current": release_b, "previous": release_a, "disabled": None},
            ],
        }
        path = self.prefix / ".transition.json"
        path.write_text(json.dumps(journal) + "\n")
        path.chmod(0o600)
        release_b_readme = self.prefix / "releases" / release_b / "README.md"
        release_b_readme.write_bytes(b"tampered\n")
        result = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn("mismatch", result.stderr)
        self.assertEqual(self.slots(), before)
        self.assertTrue(path.exists())

    def test_unknown_partial_state_is_not_recovered(self) -> None:
        self.install(self.bundle_a)
        self.install(self.bundle_b)
        current = self.prefix / "current"
        previous = self.prefix / "previous"
        current.unlink()
        current.symlink_to("releases/" + self.release_id(self.bundle_a))
        previous.unlink()
        journal = self.prefix / ".transition.json"
        journal.write_text(
            json.dumps(
                {
                    "version": 1,
                    "operationId": "0" * 32,
                    "operation": "install",
                    "trustedReleaseId": self.release_id(self.bundle_b),
                    "externalReleaseJsonSha256": sha256(self.bundle_b / "release.json"),
                    "before": {
                        "current": self.release_id(self.bundle_a),
                        "previous": None,
                        "disabled": None,
                    },
                    "after": {
                        "current": self.release_id(self.bundle_b),
                        "previous": self.release_id(self.bundle_a),
                        "disabled": None,
                    },
                    "enabledState": "enabled",
                    "phase": "intent",
                    "steps": [
                        {
                            "current": self.release_id(self.bundle_a),
                            "previous": self.release_id(self.bundle_a),
                            "disabled": None,
                        },
                        {
                            "current": self.release_id(self.bundle_b),
                            "previous": self.release_id(self.bundle_a),
                            "disabled": None,
                        },
                    ],
                }
            )
            + "\n"
        )
        journal.chmod(0o600)
        previous.symlink_to("releases/" + self.release_id(self.bundle_b))
        result = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn("transition phase does not match", result.stderr)
        self.assertTrue(journal.exists())

    def test_installed_release_and_trust_mutations_fail_closed(self) -> None:
        self.install(self.bundle_a)
        release = self.prefix / "releases" / self.release_id(self.bundle_a)
        for name, relative in (("payload", "README.md"), ("trust", ".trust.json")):
            with self.subTest(name=name):
                original = (release / relative).read_bytes()
                (release / relative).write_bytes(b"tampered\n")
                result = self.run_installer(self.bundle_a, "--disable", check=False)
                self.assertEqual(result.returncode, 64)
                message = (
                    "bundle file README.md size mismatch"
                    if name == "payload"
                    else "installed trust record is not valid JSON"
                )
                self.assertIn(message, result.stderr)
                self.assertEqual(
                    self.slots()["current"], self.release_id(self.bundle_a)
                )
                (release / relative).write_bytes(original)
                (release / relative).chmod(0o644)

        trust = release / ".trust.json"
        trust.chmod(0o600)
        result = self.run_installer(self.bundle_a, "--disable", check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn("unsafe mode", result.stderr)


class ClientPackerFailureTest(unittest.TestCase):
    def test_filesystem_failure_has_bounded_diagnostic_and_shared_exit_code(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="obsidian-packer-error-") as directory:
            parent = pathlib.Path(directory) / "not-a-directory"
            parent.write_text("preserve")
            result = subprocess.run(
                [sys.executable, str(PACK), "--output", str(parent / "bundle")],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 64, result.stderr)
            self.assertIn("obsidian-mcp-client:", result.stderr)
            self.assertIn(str(parent), result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertNotIn("incomplete bundle", result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(parent.read_text(), "preserve")

    def test_partial_write_names_retained_output_and_never_overwrites_it(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="obsidian-packer-partial-"
        ) as directory:
            root = pathlib.Path(directory).resolve()
            direct = root / "direct"
            direct.mkdir()
            alias = root / "alias"
            alias.symlink_to(direct, target_is_directory=True)
            for parent in (direct, alias):
                with self.subTest(parent=parent.name):
                    output = parent / f"bundle-{parent.name}"
                    bootstrap = """
import errno, pathlib, runpy, sys
script, output = sys.argv[1:]
target = pathlib.Path(output).resolve() / "manifest.json"
original = pathlib.Path.write_bytes
def interrupted_write(path, data):
    if path == target:
        raise OSError(errno.ENOSPC, "injected disk full", str(path))
    return original(path, data)
pathlib.Path.write_bytes = interrupted_write
sys.argv = [script, "--output", output]
runpy.run_path(script, run_name="__main__")
"""
                    result = subprocess.run(
                        [sys.executable, "-c", bootstrap, str(PACK), str(output)],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 64, result.stderr)
                    self.assertIn("injected disk full", result.stderr)
                    self.assertIn(
                        f"incomplete bundle retained; remove {output.resolve()} before retrying",
                        result.stderr,
                    )
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertTrue((output / "README.md").is_file())
                    self.assertFalse((output / "release.json").exists())
                    before = (output / "README.md").read_bytes()
                    inode = output.stat().st_ino
                    retry = subprocess.run(
                        [sys.executable, str(PACK), "--output", str(output)],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(retry.returncode, 64, retry.stderr)
                    self.assertIn("output exists but differs from this bundle", retry.stderr)
                    self.assertEqual(output.stat().st_ino, inode)
                    self.assertEqual((output / "README.md").read_bytes(), before)
                    self.assertFalse((output / "release.json").exists())


if __name__ == "__main__":
    unittest.main()
