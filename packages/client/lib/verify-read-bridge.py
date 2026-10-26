#!/usr/bin/env python3
"""Verify the immutable read bridge before packing or executing it."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
from pathlib import Path

VENDOR = "vendor/mcp-remote-read"
RUNTIME_FILES = (
    "LICENSE",
    "THIRD_PARTY_LICENSES.txt",
    "build-package.json",
    "build-package-lock.json",
    "build.py",
    "mcp-remote-read.mjs",
    "mcp-remote-read.mjs.LEGAL.txt",
    "xdg-open",
)
PATCH = "mcp-remote-0.14.3-session-recovery.patch"
FILES = (*RUNTIME_FILES, "provenance.json", PATCH)


def fail() -> None:
    raise ValueError("invalid read bridge")


def regular_bytes(root: Path, relative: str) -> bytes:
    current = root
    for part in Path(relative).parts:
        current /= part
        if stat.S_ISLNK(current.lstat().st_mode):
            fail()
    path = root / relative
    if not stat.S_ISREG(path.lstat().st_mode) or path.is_symlink():
        fail()
    if not path.resolve().is_relative_to(root.resolve()):
        fail()
    return path.read_bytes()


def verified_files(root: Path, pin: dict) -> dict[str, bytes]:
    if not isinstance(pin, dict) or set(pin) != {
        "package", "path", "provenanceSha256", "retryableTools"
    }:
        fail()
    if (
        pin["package"] != "mcp-remote@0.14.3"
        or pin["path"] != VENDOR
        or pin["retryableTools"] != ["obsidian_find_notes"]
        or not isinstance(pin["provenanceSha256"], str)
        or not re.fullmatch(r"[0-9a-f]{64}", pin["provenanceSha256"])
    ):
        fail()
    files = {f"{VENDOR}/{name}": regular_bytes(root, f"{VENDOR}/{name}") for name in FILES}
    if {path.name for path in (root / VENDOR).iterdir()} != set(FILES):
        fail()
    if not (root / VENDOR / "xdg-open").stat().st_mode & stat.S_IXUSR:
        fail()
    metadata_bytes = files[f"{VENDOR}/provenance.json"]
    if hashlib.sha256(metadata_bytes).hexdigest() != pin["provenanceSha256"]:
        fail()
    metadata = json.loads(metadata_bytes)
    if metadata.get("package") != pin["package"] or set(metadata.get("files", {})) != set(RUNTIME_FILES):
        fail()
    for relative, digest in metadata["files"].items():
        if hashlib.sha256(files[f"{VENDOR}/{relative}"]).hexdigest() != digest:
            fail()
    patch = metadata.get("patch", {})
    if patch.get("path") != PATCH or hashlib.sha256(files[f"{VENDOR}/{PATCH}"]).hexdigest() != patch.get("sha256"):
        fail()
    package = json.loads(files[f"{VENDOR}/build-package.json"])
    if package.get("name") != "obsidian-mcp-read-bridge-build" or package.get("dependencies", {}).get("esbuild") != "0.25.1":
        fail()
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.client_root.resolve()
    manifest = json.loads(regular_bytes(root, "manifest.json"))
    verified_files(root, manifest.get("readBridge"))
    print(root / VENDOR / "mcp-remote-read.mjs")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, KeyError):
        print("obsidian-mcp-client: invalid read bridge", file=sys.stderr)
        raise SystemExit(64)
