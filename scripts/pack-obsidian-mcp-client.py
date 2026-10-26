#!/usr/bin/env python3
"""Copy the allowlisted portable Obsidian MCP client bundle."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import stat
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "packages/client"
CATALOG = ROOT / "packages/client/catalog.json"
CONTRACT = ROOT / "packages/mcp-server/contract.json"
EXIT_FAILURE = 64
FILES = (
    "README.md",
    "manifest.json",
    "bin/obsidian-mcp-read",
    "bin/obsidian-mcp-write",
    "bin/obsidian-mcp-commit-event",
    "bin/obsidian-mcp-capture-commit",
    "bin/obsidian-mcp-client-install",
    "bin/obsidian-mcp-native",
    "hosts/codex-capture.md",
    "lib/launch-profile.sh",
    "lib/verify-read-bridge.py",
    "examples/profiles.env.example",
)
EXECUTABLES = {
    "bin/obsidian-mcp-read",
    "bin/obsidian-mcp-write",
    "bin/obsidian-mcp-commit-event",
    "bin/obsidian-mcp-capture-commit",
    "bin/obsidian-mcp-client-install",
    "bin/obsidian-mcp-native",
    "lib/launch-profile.sh",
    "vendor/mcp-remote-read/xdg-open",
    "vendor/mcp-remote-read/mcp-remote-read.mjs",
}


def fail(message: str) -> None:
    raise ValueError(message)


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        fail(message)


def regular_file_bytes(path: Path, label: str) -> bytes:
    try:
        item = path.lstat()
    except OSError as error:
        fail(f"cannot inspect {label}: {error.strerror}")
    if not stat.S_ISREG(item.st_mode) or item.st_nlink != 1:
        fail(f"{label} is not a private regular file")
    return path.read_bytes()


def server_reference(catalog: dict, contract_bytes: bytes) -> dict[str, str]:
    contract = json.loads(contract_bytes)
    contract_pin = catalog.get("contract", {})
    release = catalog.get("release", {})
    actual_sha256 = hashlib.sha256(contract_bytes).hexdigest()
    if contract_pin.get("sha256") != actual_sha256:
        fail("catalog contract hash does not match contract bytes")
    if contract_pin.get("contractVersion") != contract.get("contractVersion"):
        fail("catalog contract version does not match contract")
    if release.get("sourceCommit") != contract_pin.get("commit"):
        fail("catalog release source commit does not match contract pin")
    if not isinstance(release.get("tag"), str) or not release["tag"]:
        fail("catalog release tag is missing")
    return {
        "release": release["tag"],
        "contractVersion": contract_pin["contractVersion"],
        "contractSha256": actual_sha256,
        "sourceCommit": contract_pin["commit"],
    }


def source_files(catalog_path: Path, contract_path: Path) -> dict[str, bytes]:
    contract_bytes = regular_file_bytes(contract_path, "contract input")
    catalog = json.loads(regular_file_bytes(catalog_path, "catalog input"))
    files: dict[str, bytes] = {}
    for relative in FILES:
        path = SOURCE / relative
        files[relative] = regular_file_bytes(path, f"bundle source {relative}")
    manifest = json.loads(files["manifest.json"])
    verifier_path = SOURCE / "lib/verify-read-bridge.py"
    spec = importlib.util.spec_from_file_location("obsidian_read_bridge", verifier_path)
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    bridge_pin = manifest.get("readBridge")
    if bridge_pin != catalog.get("server", {}).get("readHttpBridge"):
        fail("catalog read bridge pin does not match bundle")
    verified_vendor = verifier.verified_files(SOURCE, bridge_pin)
    for relative, contents in verified_vendor.items():
        if (
            regular_file_bytes(SOURCE / relative, f"bundle source {relative}")
            != contents
        ):
            fail(f"bundle source changed during verification: {relative}")
    files.update(verified_vendor)
    manifest["pinnedServer"] = server_reference(catalog, contract_bytes)
    files["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    files["contract.json"] = contract_bytes
    return files


def release_metadata(files: dict[str, bytes]) -> bytes:
    inventory = [
        {
            "mode": 0o755 if relative in EXECUTABLES else 0o644,
            "path": relative,
            "sha256": hashlib.sha256(contents).hexdigest(),
            "size": len(contents),
        }
        for relative, contents in sorted(files.items())
    ]
    inventory_bytes = json.dumps(
        inventory, sort_keys=True, separators=(",", ":")
    ).encode()
    release_id = hashlib.sha256(inventory_bytes).hexdigest()
    manifest = json.loads(files["manifest.json"])
    capture = manifest.get("commitCapture", {})
    capture_defaults = {
        "automaticHistoricalBackfill": capture.get("automaticHistoricalBackfill"),
        "defaultActivated": capture.get("defaultActivated"),
    }
    if any(value is not False for value in capture_defaults.values()):
        fail("manifest commit capture defaults must be literal false")
    metadata = {
        "formatVersion": 1,
        "releaseId": release_id,
        "inventorySha256": release_id,
        "files": inventory,
        "pinnedServer": manifest["pinnedServer"],
        "readBridge": {
            "provenanceSha256": manifest["readBridge"]["provenanceSha256"],
        },
        "captureDefaults": capture_defaults,
    }
    return (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode()


def validate_destination(output: Path) -> Path:
    resolved = output.expanduser().resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        fail("output must be outside the repository")
    return resolved


def existing_bundle_matches(output: Path, files: dict[str, bytes]) -> bool:
    if not output.exists():
        return False
    if not output.is_dir() or output.is_symlink():
        fail("output exists but is not a directory")
    if stat.S_IMODE(output.stat().st_mode) != 0o755:
        fail("output exists but has incorrect directory permissions")
    for relative, contents in files.items():
        path = output / relative
        try:
            item = path.lstat()
        except OSError:
            fail("output exists but differs from this bundle")
        if (
            not stat.S_ISREG(item.st_mode)
            or item.st_nlink != 1
            or path.read_bytes() != contents
        ):
            fail("output exists but differs from this bundle")
        expected_mode = 0o755 if relative in EXECUTABLES else 0o644
        if stat.S_IMODE(path.stat().st_mode) != expected_mode:
            fail("output exists but has incorrect permissions")
    expected_entries = set(files)
    for relative in files:
        expected_entries.update(
            parent.as_posix()
            for parent in Path(relative).parents
            if parent != Path(".")
        )
    actual = set()
    for path in output.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            fail("output exists but contains unsafe entries")
        if path.is_dir() and stat.S_IMODE(path.stat().st_mode) != 0o755:
            fail("output exists but has incorrect directory permissions")
        actual.add(path.relative_to(output).as_posix())
    if actual != expected_entries:
        fail("output exists but contains unallowlisted files")
    return True


def write_bundle(output: Path, files: dict[str, bytes]) -> None:
    output.mkdir(parents=True, exist_ok=False)
    try:
        output.chmod(0o755)
        for relative, contents in files.items():
            path = output / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
            path.chmod(0o755 if relative in EXECUTABLES else 0o644)
        for path in output.rglob("*"):
            if path.is_dir():
                path.chmod(0o755)
    except OSError as error:
        fail(
            f"could not finish bundle at {output}: {error}; "
            f"incomplete bundle retained; remove {output} before retrying"
        )


def main() -> int:
    parser = ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--contract", type=Path, default=CONTRACT)
    args = parser.parse_args()
    files = source_files(args.catalog.resolve(), args.contract.resolve())
    files["release.json"] = release_metadata(files)
    release_sha256 = hashlib.sha256(files["release.json"]).hexdigest()
    output = validate_destination(args.output)
    if existing_bundle_matches(output, files):
        print(f"obsidian-mcp-client: up to date at {output}")
        print(f"obsidian-mcp-client: release.json sha256 {release_sha256}")
        return 0
    write_bundle(output, files)
    print(f"obsidian-mcp-client: packed {len(files)} files at {output}")
    print(f"obsidian-mcp-client: release.json sha256 {release_sha256}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as error:
        print(f"obsidian-mcp-client: {error}", file=sys.stderr)
        raise SystemExit(EXIT_FAILURE)
