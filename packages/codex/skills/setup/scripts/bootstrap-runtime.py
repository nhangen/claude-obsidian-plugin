#!/usr/bin/env python3
"""Authenticate and stage the public runtime; delegate lifecycle to its installer."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unicodedata
import urllib.parse
import urllib.request


REPOSITORY = "nhangen/obsidian-mcp"
TAG = "client-v0.3.0"
INSTALLER = "obsidian-mcp-client-install"
METADATA = "obsidian-mcp-client.release.json"
ARCHIVE = "obsidian-mcp-client.tgz"
ASSETS = (INSTALLER, METADATA, ARCHIVE)
ROOT = "obsidian-mcp-client"
MAX_ASSET_BYTES = 2 * 1024 * 1024
MAX_TAR_BYTES = 8 * 1024 * 1024
MAX_PAYLOAD_BYTES = 6 * 1024 * 1024
MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_MEMBERS = 128
REQUEST_TIMEOUT = 10
DOWNLOAD_SECONDS = 45
INSTALL_SECONDS = 60
HEX64 = re.compile(r"[0-9a-f]{64}")


class BootstrapError(Exception):
    pass


def fail(message: str):
    raise BootstrapError(message)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        fail("invalid arguments; use --help")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path: Path, limit: int) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        item = os.fstat(source.fileno())
        if not stat.S_ISREG(item.st_mode) or item.st_nlink != 1:
            fail("offline input must be a single-link regular file")
        if item.st_size > limit:
            fail("asset authentication failed: size limit exceeded")
        data = source.read(limit + 1)
        if len(data) != item.st_size or len(data) > limit:
            fail("asset authentication failed: input changed or exceeded size limit")
        return data


def read_pin() -> dict:
    pin = json.loads(regular_bytes(Path(__file__).with_name(f"{TAG}.pin.json"), 16384))
    if (
        pin.get("repository") != REPOSITORY
        or pin.get("tag") != TAG
        or not isinstance(pin.get("releaseId"), str)
        or not HEX64.fullmatch(pin["releaseId"])
        or set(pin.get("assets", {})) != set(ASSETS)
    ):
        fail("packaged release pin is invalid")
    for entry in pin["assets"].values():
        if (
            set(entry) != {"sha256", "size"}
            or type(entry["size"]) is not int
            or not 0 < entry["size"] <= MAX_ASSET_BYTES
            or not isinstance(entry["sha256"], str)
            or not HEX64.fullmatch(entry["sha256"])
        ):
            fail("packaged asset pin is invalid")
    return pin


def validate_assets_directory(path: Path):
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        item = current.lstat()
        if stat.S_ISLNK(item.st_mode):
            if (
                current in (Path("/tmp"), Path("/var"), Path("/etc"))
                and item.st_uid == 0
            ):
                continue
            fail("offline asset directory contains a symlink")
        if not stat.S_ISDIR(item.st_mode):
            fail("offline asset directory is not a directory")


def remaining(deadline: float) -> float:
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        fail("public release download timed out")
    return min(REQUEST_TIMEOUT, seconds)


@contextmanager
def download_budget(enabled: bool):
    if not enabled:
        yield
        return

    def expired(signum, frame):
        fail("public release download timed out")

    # Socket inactivity limits alone cannot bound a slowly streaming response.
    previous_handler = signal.signal(signal.SIGALRM, expired)
    previous_timer = signal.setitimer(signal.ITIMER_REAL, DOWNLOAD_SECONDS)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, *previous_timer)
        signal.signal(signal.SIGALRM, previous_handler)


class ReleaseRedirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 3
    max_repeats = 1

    def __init__(self, deadline):
        self.deadline = deadline

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        remaining(self.deadline)
        url = urllib.parse.urlsplit(newurl)
        if (
            url.scheme != "https"
            or url.username
            or url.password
            or url.port not in (None, 443)
            or url.hostname
            not in {
                "github.com",
                "release-assets.githubusercontent.com",
                "objects.githubusercontent.com",
            }
        ):
            fail("public release redirect refused")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        redirected.timeout = remaining(self.deadline)
        return redirected


def download(name: str, size: int, deadline: float) -> bytes:
    request = urllib.request.Request(
        f"https://github.com/{REPOSITORY}/releases/download/{TAG}/{name}",
        headers={"User-Agent": "obsidian-codex-setup", "Accept-Encoding": "identity"},
    )
    opener = urllib.request.build_opener(ReleaseRedirects(deadline))
    with opener.open(request, timeout=remaining(deadline)) as response:
        chunks = []
        count = 0
        while count <= size:
            remaining(deadline)
            chunk = response.read(min(65536, size + 1 - count))
            remaining(deadline)
            if not chunk:
                break
            chunks.append(chunk)
            count += len(chunk)
        if count != size:
            fail("asset authentication failed: download size mismatch")
        return b"".join(chunks)


def authenticated_assets(pin: dict, offline: Path | None) -> dict[str, bytes]:
    if offline is not None:
        validate_assets_directory(offline)
    deadline = time.monotonic() + DOWNLOAD_SECONDS
    assets = {}
    for name in ASSETS:
        entry = pin["assets"][name]
        data = (
            regular_bytes(offline / name, entry["size"])
            if offline is not None
            else download(name, entry["size"], deadline)
        )
        if len(data) != entry["size"] or sha256(data) != entry["sha256"]:
            fail("asset authentication failed: size or SHA-256 mismatch")
        assets[name] = data
    return assets


def unpack(data: bytes, destination: Path, metadata: bytes, release_id: str) -> Path:
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
        expanded = compressed.read(MAX_TAR_BYTES + 1)
    if len(expanded) > MAX_TAR_BYTES:
        fail("archive expanded size limit exceeded")
    if len(expanded) % 512 or not expanded.endswith(b"\0" * 1024):
        fail("archive is truncated")
    with tarfile.open(fileobj=io.BytesIO(expanded), mode="r:") as archive:
        members = []
        names = {}
        spellings = {}
        total = 0
        end = 0
        for member in archive:
            if len(members) >= MAX_MEMBERS:
                fail("archive member count limit exceeded")
            name = member.name
            header = expanded[member.offset : member.offset + 512]
            raw_name = header[:100].split(b"\0", 1)[0].decode("utf-8")
            if header[257:263] == b"ustar\0":
                prefix = header[345:500].split(b"\0", 1)[0].decode("utf-8")
                if prefix:
                    raw_name = f"{prefix}/{raw_name}"
            # tarfile strips directory slashes and consumes extension headers.
            if member.offset_data != member.offset + 512 or raw_name not in (
                name,
                name + "/" if member.isdir() else name,
            ):
                fail("archive contains a noncanonical header")
            path = PurePosixPath(name)
            if (
                not name
                or "\\" in name
                or any(ord(c) < 32 for c in name)
                or path.is_absolute()
                or path.as_posix() != name
                or ".." in path.parts
                or path.parts[0] != ROOT
                or member.pax_headers
                or not (member.isdir() or member.isreg())
                or member.mode not in (0o644, 0o755)
                or (member.isdir() and (member.mode != 0o755 or member.size != 0))
                or member.size < 0
                or member.size > MAX_FILE_BYTES
            ):
                fail("archive contains an unsafe member")
            folded = unicodedata.normalize("NFC", name).casefold()
            if folded in names:
                fail("archive contains duplicate or colliding names")
            names[folded] = member.isdir()
            for component in (path, *path.parents):
                spelling = component.as_posix()
                key = unicodedata.normalize("NFC", spelling).casefold()
                if key in spellings and spellings[key] != spelling:
                    fail("archive contains colliding path components")
                spellings[key] = spelling
            total += member.size
            if total > MAX_PAYLOAD_BYTES:
                fail("archive payload size limit exceeded")
            members.append(member)
            end = member.offset_data + ((member.size + 511) // 512) * 512
        if not members or any(expanded[end:]):
            fail("archive has unexpected trailing content")
        for member in members:
            for parent in PurePosixPath(member.name).parents:
                key = unicodedata.normalize("NFC", parent.as_posix()).casefold()
                if key in names and not names[key]:
                    fail("archive contains a file/directory collision")
        for member in members:
            target = destination / member.name
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            if member.isdir():
                target.mkdir(exist_ok=True, mode=0o755)
            else:
                with archive.extractfile(member) as source, target.open("xb") as output:
                    output.write(source.read(member.size + 1))
            target.chmod(member.mode)
    bundle = destination / ROOT
    embedded = regular_bytes(bundle / "release.json", 65536)
    if embedded != metadata:
        fail("embedded release metadata authentication failed")
    if json.loads(embedded).get("releaseId") != release_id:
        fail("embedded release identity does not match the packaged pin")
    return bundle


def main() -> int:
    parser = Parser(description=__doc__)
    parser.add_argument(
        "--apply", action="store_true", help="apply the requested lifecycle change"
    )
    parser.add_argument(
        "--assets",
        type=Path,
        help="offline directory containing the three pinned assets",
    )
    parser.add_argument(
        "--prefix",
        type=Path,
        help="public installer prefix (default: ~/.local/share/obsidian-mcp-client)",
    )
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument(
        "--reinstall",
        action="store_true",
        help="verify/reuse the pinned release through the public installer",
    )
    actions.add_argument("--disable", action="store_true")
    actions.add_argument("--enable", action="store_true")
    actions.add_argument("--rollback", action="store_true")
    args = parser.parse_args()
    if not os.environ.get("HOME"):
        fail("HOME is required")
    pin = read_pin()
    offline = Path(os.path.abspath(args.assets.expanduser())) if args.assets else None
    with download_budget(offline is None):
        assets = authenticated_assets(pin, offline)
    with tempfile.TemporaryDirectory(prefix="obsidian-codex-runtime-") as temporary:
        staging = Path(temporary).resolve()
        staging.chmod(0o700)
        bundle = unpack(assets[ARCHIVE], staging, assets[METADATA], pin["releaseId"])
        installer = staging / INSTALLER
        installer.write_bytes(assets[INSTALLER])
        command = [sys.executable, "-I", "-B", str(installer)]
        if args.prefix is not None:
            command += ["--prefix", str(args.prefix)]
        operation = next(
            (name for name in ("disable", "enable", "rollback") if getattr(args, name)),
            None,
        )
        if operation:
            command.append(f"--{operation}")
        else:
            command += [
                "--bundle",
                str(bundle),
                "--release-sha256",
                pin["assets"][METADATA]["sha256"],
            ]
        if not args.apply:
            command.append("--dry-run")
        # Installer errors may contain host paths or hostile installed metadata.
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=INSTALL_SECONDS,
            check=False,
            env={"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin"},
        )
        if result.returncode:
            fail(
                "verified public installer refused the operation; check prefix integrity, lifecycle state, or required recovery"
            )
        if args.apply:
            print(
                f"Public runtime {operation or 'install'} verified/applied; profiles and capture remain separately configured."
            )
        else:
            plan = json.loads(result.stdout)
            if (
                set(plan) != {"after", "before", "dryRun", "operation"}
                or plan["dryRun"] is not True
                or plan["operation"] != (operation or "install")
            ):
                fail("verified public installer returned an invalid preview")
            for slots in (plan["before"], plan["after"]):
                if (
                    not isinstance(slots, dict)
                    or set(slots) != {"current", "previous", "disabled"}
                    or any(
                        value is not None
                        and (not isinstance(value, str) or not HEX64.fullmatch(value))
                        for value in slots.values()
                    )
                ):
                    fail("verified public installer returned invalid runtime slots")
            print(json.dumps(plan, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BootstrapError as error:
        print(f"obsidian setup: {error}", file=sys.stderr)
        raise SystemExit(64)
    except subprocess.TimeoutExpired:
        print(
            "obsidian setup: public installer timed out; check recovery before retrying",
            file=sys.stderr,
        )
        raise SystemExit(64)
    except Exception:
        print(
            "obsidian setup: release unavailable or invalid; check offline assets, network, or packaged pins",
            file=sys.stderr,
        )
        raise SystemExit(64)
