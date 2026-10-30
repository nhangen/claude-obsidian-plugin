#!/usr/bin/env python3
"""Exercise the packaged setup entrypoint in isolated homes, without a checkout."""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
NAMES = (
    "obsidian-mcp-client-install",
    "obsidian-mcp-client.release.json",
    "obsidian-mcp-client.tgz",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class BootstrapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="codex-bootstrap-bundle-")
        cls.bundle = Path(cls.fixture.name) / "bundle"
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/pack-obsidian-mcp-client.py"),
                "--output",
                str(cls.bundle),
            ],
            check=True,
            capture_output=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-bootstrap-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.stage = self.root / "temp"
        self.stage.mkdir()
        self.skill = self.root / "installed/skills/setup"
        shutil.copytree(
            Path(
                os.environ.get(
                    "CODEX_BOOTSTRAP_INSTALLED_SKILL",
                    ROOT / "packages/codex/skills/setup",
                )
            ),
            self.skill,
        )
        self.script = self.skill / "scripts/bootstrap-runtime.py"
        self.pin_path = self.skill / "scripts/client-v0.3.0.pin.json"
        self.pin = json.loads(self.pin_path.read_bytes())
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.prefix = self.home / "runtime"
        self.env = {
            "HOME": str(self.home),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": str(self.stage),
            "PYTHONDONTWRITEBYTECODE": "1",
            "XDG_CONFIG_HOME": str(self.home / "config"),
        }
        (self.assets / NAMES[0]).write_bytes(
            (self.bundle / "bin/obsidian-mcp-client-install").read_bytes()
        )
        (self.assets / NAMES[1]).write_bytes(
            (self.bundle / "release.json").read_bytes()
        )
        self.archive_bundle()
        self.repin()

    def archive_bundle(self):
        with tarfile.open(
            self.assets / NAMES[2], "w:gz", format=tarfile.USTAR_FORMAT
        ) as archive:
            archive.add(self.bundle, arcname="obsidian-mcp-client")

    def repin(self):
        for name in NAMES:
            data = (self.assets / name).read_bytes()
            self.pin["assets"][name] = {"sha256": digest(data), "size": len(data)}
        self.pin["releaseId"] = json.loads((self.assets / NAMES[1]).read_bytes())[
            "releaseId"
        ]
        self.pin_path.write_text(json.dumps(self.pin))

    def run_setup(self, *args, ok=True, offline=True, harness=None):
        command = (
            [sys.executable, "-c", harness, str(self.script)]
            if harness
            else [sys.executable, str(self.script)]
        )
        command += ["--prefix", str(self.prefix)]
        if offline:
            command += ["--assets", str(self.assets)]
        result = subprocess.run(
            command + list(args),
            cwd=self.home,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(list(self.stage.iterdir()), [], "private staging leaked")
        return result

    def snapshot(self):
        return sorted(
            (
                str(p.relative_to(self.home)),
                os.readlink(p)
                if p.is_symlink()
                else p.read_bytes()
                if p.is_file()
                else None,
            )
            for p in self.home.rglob("*")
        )

    def test_installed_entrypoint_preview_does_not_write_persistent_state(self):
        before = self.snapshot()
        result = self.run_setup()
        self.assertTrue(json.loads(result.stdout)["dryRun"])
        self.assertEqual(self.snapshot(), before)

    def test_apply_reinstall_and_disabled_state_retention(self):
        self.run_setup("--apply")
        release = (self.prefix / "current").resolve()
        inode = release.stat().st_ino
        self.run_setup("--reinstall", "--apply")
        self.assertEqual(release.stat().st_ino, inode)
        before = self.snapshot()
        self.run_setup("--reinstall")
        self.assertEqual(self.snapshot(), before)
        self.run_setup("--disable")
        self.assertEqual(self.snapshot(), before)
        self.run_setup("--disable", "--apply")
        self.assertTrue((self.prefix / "disabled").is_symlink())
        self.run_setup("--apply")
        self.assertFalse((self.prefix / "current").exists())
        before = self.snapshot()
        self.run_setup("--enable")
        self.assertEqual(self.snapshot(), before)
        self.run_setup("--enable", "--apply")
        self.assertTrue((self.prefix / "current").is_symlink())

    def test_every_asset_authenticates_before_any_installer_execution(self):
        original = {name: (self.assets / name).read_bytes() for name in NAMES}
        marker = self.home / "executed"
        (self.assets / NAMES[0]).write_text(
            f"from pathlib import Path\nPath({str(marker)!r}).touch()\n"
        )
        self.repin()
        for name in NAMES:
            with self.subTest(asset=name):
                data = (self.assets / name).read_bytes()
                (self.assets / name).write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
                result = self.run_setup("--apply", ok=False)
                self.assertIn("asset authentication failed", result.stderr)
                self.assertFalse(marker.exists())
                self.assertFalse(self.prefix.exists())
                (self.assets / name).write_bytes(data)
        for name, data in original.items():
            (self.assets / name).write_bytes(data)

    def test_existing_installer_is_never_executed_and_tamper_is_refused(self):
        self.run_setup("--apply")
        installed = self.prefix / "current/bin/obsidian-mcp-client-install"
        marker = self.home / "cached-installer-executed"
        installed.write_text(
            f"from pathlib import Path\nPath({str(marker)!r}).touch()\n"
            "raise SystemExit('SECRET_SENTINEL')\n"
        )
        result = self.run_setup("--reinstall", "--apply", ok=False)
        self.assertFalse(marker.exists(), "cached installer was executed")
        self.assertNotIn("SECRET_SENTINEL", result.stderr)
        self.assertIn("installer", result.stderr)

    def test_recovery_required_preview_refuses_without_changing_journal(self):
        self.run_setup("--apply")
        journal = self.prefix / ".transition.json"
        journal.write_text("SECRET_SENTINEL")
        before = self.snapshot()
        self.run_setup(ok=False)
        self.assertEqual(self.snapshot(), before)

    def test_offline_symlink_hardlink_fifo_and_directory_are_rejected(self):
        path = self.assets / NAMES[0]
        original = path.read_bytes()
        other = self.root / "other"
        other.write_bytes(original)
        for kind in ("symlink", "hardlink", "fifo", "directory"):
            with self.subTest(kind=kind):
                path.unlink()
                if kind == "symlink":
                    path.symlink_to(other)
                elif kind == "hardlink":
                    os.link(other, path)
                elif kind == "fifo":
                    os.mkfifo(path)
                else:
                    path.mkdir()
                self.run_setup("--apply", ok=False)
                if path.is_dir():
                    path.rmdir()
                else:
                    path.unlink()
                path.write_bytes(original)

    def bad_archive(self, members):
        output = io.BytesIO()
        with tarfile.open(
            fileobj=output, mode="w", format=tarfile.USTAR_FORMAT
        ) as archive:
            for name, kind, contents in members:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
                member.size = len(contents) if kind == tarfile.REGTYPE else 0
                member.linkname = (
                    "../../escaped"
                    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE)
                    else ""
                )
                archive.addfile(member, io.BytesIO(contents))
        (self.assets / NAMES[2]).write_bytes(gzip.compress(output.getvalue()))
        self.repin()

    def test_unsafe_archives_cannot_escape_or_execute(self):
        normal = ("obsidian-mcp-client/ok", tarfile.REGTYPE, b"ok")
        cases = [
            [("/escaped", tarfile.REGTYPE, b"bad")],
            [("obsidian-mcp-client/../../escaped", tarfile.REGTYPE, b"bad")],
            [("obsidian-mcp-client/./bad", tarfile.REGTYPE, b"bad")],
            [("obsidian-mcp-client//bad", tarfile.REGTYPE, b"bad")],
            [("obsidian-mcp-client/bad//", tarfile.DIRTYPE, b"")],
            [("unexpected/root", tarfile.REGTYPE, b"bad")],
            [normal, normal],
            [normal, ("obsidian-mcp-client/OK", tarfile.REGTYPE, b"bad")],
            [normal, ("obsidian-mcp-client/ok/file", tarfile.REGTYPE, b"bad")],
            [
                ("obsidian-mcp-client/A/file", tarfile.REGTYPE, b"a"),
                ("obsidian-mcp-client/a/other", tarfile.REGTYPE, b"b"),
            ],
        ]
        for kind in (
            tarfile.SYMTYPE,
            tarfile.LNKTYPE,
            tarfile.FIFOTYPE,
            tarfile.CHRTYPE,
            tarfile.BLKTYPE,
        ):
            cases.append([("obsidian-mcp-client/bad", kind, b"")])
        for members in cases:
            with self.subTest(members=members):
                self.bad_archive(members)
                result = self.run_setup("--apply", ok=False)
                self.assertIn("archive", result.stderr)
                self.assertFalse((self.root / "escaped").exists())
                self.assertFalse(self.prefix.exists())

    def test_embedded_metadata_must_match_outer_pin(self):
        self.pin["releaseId"] = "0" * 64
        self.pin_path.write_text(json.dumps(self.pin))
        self.run_setup("--apply", ok=False)
        self.assertFalse(self.prefix.exists())

    def test_offline_makes_zero_network_requests(self):
        harness = """
import runpy, sys, urllib.request
def forbidden(*args, **kwargs):
    raise AssertionError('SECRET_SENTINEL network called in offline mode')
urllib.request.build_opener = forbidden
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
"""
        self.run_setup(harness=harness)

    def network_harness(self, behavior):
        return f"""
import io, pathlib, runpy, sys, urllib.request, urllib.error
assets = pathlib.Path({str(self.assets)!r})
class Response(io.BytesIO):
    def read(self, size):
        if size < 1 or size > 65536:
            raise AssertionError('unbounded read')
        return super().read(size)
class Opener:
    def open(self, request, timeout):
        assert 0 < timeout <= 10
        assert request.full_url.startswith('https://github.com/nhangen/obsidian-mcp/releases/download/client-v0.3.0/')
        name = request.full_url.rsplit('/', 1)[-1]
        data = (assets / name).read_bytes()
        behavior = {behavior!r}
        if behavior == 'exception':
            raise urllib.error.URLError('SECRET_SENTINEL response body')
        if behavior == 'timeout':
            raise TimeoutError('SECRET_SENTINEL signed URL')
        if behavior == 'oversize':
            data += b'x' * 100000
        if behavior == 'short':
            data = data[:-1]
        return Response(data)
urllib.request.build_opener = lambda *args: Opener()
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
"""

    def test_network_uses_fixed_urls_bounded_reads_and_timeouts(self):
        self.run_setup(offline=False, harness=self.network_harness("success"))
        self.assertFalse(self.prefix.exists())
        for behavior in ("exception", "timeout", "oversize", "short"):
            with self.subTest(behavior=behavior):
                result = self.run_setup(
                    "--apply",
                    ok=False,
                    offline=False,
                    harness=self.network_harness(behavior),
                )
                self.assertNotIn("SECRET_SENTINEL", result.stderr)
                self.assertFalse(self.prefix.exists())

    def test_total_download_deadline_is_enforced(self):
        harness = self.network_harness("success").replace(
            "sys.argv = sys.argv[1:]",
            """import time
times = iter([0, 0, 46])
time.monotonic = lambda: next(times)
sys.argv = sys.argv[1:]""",
        )
        result = self.run_setup(ok=False, offline=False, harness=harness)
        self.assertIn("timed out", result.stderr)

    def test_installer_timeout_is_sanitized_and_staging_is_cleaned(self):
        harness = """
import runpy, sys, subprocess
def timeout(*args, **kwargs):
    assert 0 < kwargs['timeout'] <= 60
    raise subprocess.TimeoutExpired('SECRET_SENTINEL', kwargs['timeout'])
subprocess.run = timeout
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
"""
        result = self.run_setup(ok=False, harness=harness)
        self.assertIn("installer timed out", result.stderr)
        self.assertNotIn("SECRET_SENTINEL", result.stderr)

    def test_download_deadline_interrupts_a_stalled_response(self):
        harness = (
            self.network_harness("success")
            .replace(
                "return super().read(size)",
                "import time; time.sleep(0.2); return super().read(size)",
            )
            .replace(
                "sys.argv = sys.argv[1:]",
                """import signal
real_timer = signal.setitimer
def timer(which, seconds, *args):
    return real_timer(which, 0.02 if seconds == 45 else seconds, *args)
signal.setitimer = timer
sys.argv = sys.argv[1:]""",
            )
        )
        result = self.run_setup(ok=False, offline=False, harness=harness)
        self.assertIn("download timed out", result.stderr)

    def test_network_rejects_redirects_outside_public_release_hosts(self):
        for url in (
            "http://github.com/SECRET_SENTINEL",
            "https://example.com/SECRET_SENTINEL",
            "https://token:SECRET_SENTINEL@github.com/asset",
        ):
            with self.subTest(url=url):
                harness = self.network_harness("success").replace(
                    "urllib.request.build_opener = lambda *args: Opener()",
                    f"""def build_opener(handler):
    class RedirectOpener(Opener):
        def open(self, request, timeout):
            request.timeout = timeout
            handler.redirect_request(request, None, 302, 'redirect', {{}}, {url!r})
            return super().open(request, timeout)
    return RedirectOpener()
urllib.request.build_opener = build_opener""",
                )
                result = self.run_setup(ok=False, offline=False, harness=harness)
                self.assertIn("redirect refused", result.stderr)
                self.assertNotIn("SECRET_SENTINEL", result.stderr)

    def test_offline_asset_directory_symlink_is_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.assets, target_is_directory=True)
        self.assets = alias
        self.run_setup("--apply", ok=False)
        self.assertFalse(self.prefix.exists())

    def test_preview_rejects_invalid_installer_output_without_leaking_it(self):
        (self.assets / NAMES[0]).write_text("print('SECRET_SENTINEL')\n")
        self.repin()
        result = self.run_setup(ok=False)
        self.assertNotIn("SECRET_SENTINEL", result.stdout + result.stderr)

    def test_recovery_is_owned_by_public_installer(self):
        installer = self.bundle / "bin/obsidian-mcp-client-install"
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                str(installer),
                "--prefix",
                str(self.prefix),
                "--bundle",
                str(self.bundle),
                "--release-sha256",
                self.pin["assets"][NAMES[1]]["sha256"],
            ],
            cwd=self.home,
            capture_output=True,
            timeout=15,
            env={
                **self.env,
                "OBSIDIAN_MCP_CLIENT_TEST_ROOT": str(self.home),
                "OBSIDIAN_MCP_CLIENT_TEST_FAIL_AFTER": "intent_persisted",
            },
        )
        self.assertEqual(result.returncode, 86)
        self.assertTrue((self.prefix / ".transition.json").is_file())
        before = self.snapshot()
        self.run_setup(ok=False)
        self.assertEqual(self.snapshot(), before)
        self.run_setup("--apply")
        self.assertFalse((self.prefix / ".transition.json").exists())
        self.assertTrue((self.prefix / "current").is_symlink())

    def test_archive_member_file_payload_and_expansion_limits(self):
        cases = [
            [(f"obsidian-mcp-client/f{i}", tarfile.REGTYPE, b"") for i in range(129)],
            [
                (
                    "obsidian-mcp-client/large",
                    tarfile.REGTYPE,
                    b"x" * (5 * 1024 * 1024 + 1),
                )
            ],
            [
                (f"obsidian-mcp-client/f{i}", tarfile.REGTYPE, b"x" * (3200 * 1024))
                for i in range(2)
            ],
            [("obsidian-mcp-client/large", tarfile.REGTYPE, b"x" * (9 * 1024 * 1024))],
        ]
        for members in cases:
            with self.subTest(sizes=[len(m[2]) for m in members]):
                self.bad_archive(members)
                result = self.run_setup("--apply", ok=False)
                self.assertIn("archive", result.stderr)
                self.assertFalse(self.prefix.exists())

    def test_compressed_asset_size_limit(self):
        archive = self.assets / NAMES[2]
        archive.write_bytes(b"x" * (2 * 1024 * 1024 + 1))
        self.repin()
        self.run_setup("--apply", ok=False)
        self.assertFalse(self.prefix.exists())

    def test_archive_truncation_corrupt_gzip_and_missing_end_markers(self):
        original = (self.assets / NAMES[2]).read_bytes()
        expanded = gzip.decompress(original)
        for data in (
            original[:-16],
            b"not gzip",
            gzip.compress(expanded[:600]),
            original[:200] + b"corruption" + original[210:],
        ):
            with self.subTest(length=len(data)):
                (self.assets / NAMES[2]).write_bytes(data)
                self.repin()
                self.run_setup("--apply", ok=False)
                self.assertFalse(self.prefix.exists())

    def test_embedded_metadata_bytes_must_match_outer_asset(self):
        metadata = self.assets / NAMES[1]
        metadata.write_bytes(metadata.read_bytes() + b"\n")
        self.repin()
        self.run_setup("--apply", ok=False)
        self.assertFalse(self.prefix.exists())

    def test_lifecycle_rollback_delegates_and_previews_without_mutation(self):
        self.run_setup("--apply")
        first = (self.prefix / "current").resolve().name
        second = self.root / "second-bundle"
        source = self.root / "packer-source"
        shutil.copytree(ROOT / "packages/client", source / "packages/client")
        (source / "scripts").mkdir()
        packer = source / "scripts/pack-obsidian-mcp-client.py"
        shutil.copy2(ROOT / "scripts/pack-obsidian-mcp-client.py", packer)
        (source / "packages/mcp-server").mkdir()
        shutil.copy2(
            ROOT / "packages/mcp-server/contract.json",
            source / "packages/mcp-server/contract.json",
        )
        readme = source / "packages/client/README.md"
        readme.write_bytes(readme.read_bytes() + b"\nSynthetic second release\n")
        subprocess.run(
            [sys.executable, str(packer), "--output", str(second)],
            cwd=source,
            env=self.env,
            check=True,
            capture_output=True,
            timeout=15,
        )
        identity = json.loads((second / "release.json").read_bytes())["releaseId"]
        self.assertNotEqual(identity, first)
        self.bundle = second
        (self.assets / NAMES[1]).write_bytes((second / "release.json").read_bytes())
        self.archive_bundle()
        self.repin()
        self.run_setup("--apply")
        self.assertEqual((self.prefix / "previous").resolve().name, first)
        before = self.snapshot()
        result = self.run_setup("--rollback")
        self.assertEqual(json.loads(result.stdout)["operation"], "rollback")
        self.assertEqual(self.snapshot(), before)
        self.run_setup("--rollback", "--apply")
        self.assertEqual((self.prefix / "current").resolve().name, first)
        self.assertEqual((self.prefix / "previous").resolve().name, identity)

    def test_unknown_pin_and_url_options_are_not_supported(self):
        for option in ("--pin", "--url"):
            result = self.run_setup(option, "SECRET_SENTINEL", ok=False)
            self.assertNotIn("SECRET_SENTINEL", result.stderr)


@unittest.skipUnless(
    os.environ.get("OBSIDIAN_CODEX_BOOTSTRAP_ASSETS"),
    "set OBSIDIAN_CODEX_BOOTSTRAP_ASSETS to the public pinned release fixture",
)
class PublicReleaseTest(unittest.TestCase):
    def test_actual_pinned_release_from_installed_package(self):
        with tempfile.TemporaryDirectory(prefix="codex-bootstrap-public-") as temporary:
            root = Path(temporary).resolve()
            skill = root / "plugin/skills/setup"
            shutil.copytree(
                Path(
                    os.environ.get(
                        "CODEX_BOOTSTRAP_INSTALLED_SKILL",
                        ROOT / "packages/codex/skills/setup",
                    )
                ),
                skill,
            )
            home = root / "home"
            home.mkdir()
            prefix = home / "runtime"
            command = [
                sys.executable,
                str(skill / "scripts/bootstrap-runtime.py"),
                "--assets",
                os.environ["OBSIDIAN_CODEX_BOOTSTRAP_ASSETS"],
                "--prefix",
                str(prefix),
            ]
            env = {
                "HOME": str(home),
                "PATH": "/usr/bin:/bin",
                "PYTHONDONTWRITEBYTECODE": "1",
            }
            for args in (
                [],
                ["--apply"],
                [],
                ["--reinstall", "--apply"],
                ["--disable", "--apply"],
                ["--apply"],
                ["--enable", "--apply"],
            ):
                result = subprocess.run(
                    command + args,
                    cwd=home,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if not args:
                    self.assertTrue(json.loads(result.stdout)["dryRun"])
            pin = json.loads((skill / "scripts/client-v0.3.0.pin.json").read_bytes())
            self.assertEqual((prefix / "current").resolve().name, pin["releaseId"])
            self.assertFalse((home / ".config").exists())


if __name__ == "__main__":
    unittest.main()
