#!/usr/bin/env python3
"""Generate shared package files and advance the marketplace version on source change."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CODEX = "packages/codex/skills/commit-capture/scripts/"
MCP = "packages/mcp-server/helpers/"
LOCK = ".agents/plugins/obsidian-package-state.json"
MANIFESTS = (
    ".claude-plugin/plugin.json",
    ".claude-plugin/marketplace.json",
    "packages/codex/.codex-plugin/plugin.json",
)
VENDORS = {
    CODEX + name: "scripts/" + name
    for name in (
        "commit-meta.sh", "keeper", "keeper-core", "lib/capture-owner.py",
        "lib/obsidian-mcp-client-install", "lib/commit-capture-parse.sh",
        "lib/note-hash.sh", "lib/resolve-config.sh", "lib/vault-index.sh",
    )
} | {
    MCP + name: "scripts/" + ("keeper-core" if name == "keeper" else name)
    for name in (
        "commit-meta.sh", "keeper", "lib/allowlist-validate.sh",
        "lib/commit-capture-parse.sh", "lib/dedup-scan.sh", "lib/note-hash.sh",
        "lib/resolve-config.sh", "lib/vault-index.sh",
    )
}
VERSION = re.compile(r'(\s*"version"\s*:\s*")([0-9]+\.[0-9]+\.[0-9]+)(")')


def version_tuple(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError(f"unsupported plugin version: {value}")
    return tuple(map(int, value.split(".")))


def version_text(text, version):
    result, count = VERSION.subn(lambda m: m[1] + version + m[3], text)
    if count != 1:
        raise ValueError("expected one plugin version per manifest")
    return result


def tracked_inputs():
    files = subprocess.check_output([
        "git", "ls-files", "-z", "--", ".agents/plugins/marketplace.json",
        ".claude-plugin", "agents", "commands", "hooks", "scripts", "skills",
        "packages",
    ], cwd=ROOT)
    return sorted(set(files.decode().split("\0")) - {"", *VENDORS})


def desired_files():
    digest = hashlib.sha256()
    for name in tracked_inputs():
        path = ROOT / name
        if not path.is_file():
            continue
        data = (version_text(path.read_text(), "0.0.0").encode()
                if name in MANIFESTS else path.read_bytes())
        digest.update(json.dumps([name, bool(path.stat().st_mode & stat.S_IXUSR),
                                  hashlib.sha256(data).hexdigest()]).encode())
    fingerprint = digest.hexdigest()
    versions = []
    for name in MANIFESTS:
        data = json.loads((ROOT / name).read_text())
        versions.append(version_tuple((data["plugins"][0] if "plugins" in data else data)["version"]))
    lock = ROOT / LOCK
    previous = json.loads(lock.read_text()) if lock.exists() else None
    current = max(versions)
    if previous and version_tuple(previous["version"]) > current:
        current = version_tuple(previous["version"])
    if not previous or previous["fingerprint"] != fingerprint:
        if not previous or current == version_tuple(previous["version"]):
            current = (*current[:2], current[2] + 1)
    version = ".".join(map(str, current))
    result = {
        name: version_text((ROOT / name).read_text(), version).encode()
        for name in MANIFESTS
    }
    for target, source in VENDORS.items():
        data = (ROOT / source).read_bytes()
        if target == CODEX + "keeper":
            data = data.replace(b"legacy -- bash", b"legacy --host codex -- bash")
        result[target] = data
    result[LOCK] = (json.dumps(dict(version=version, fingerprint=fingerprint), indent=2) + "\n").encode()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify without modifying files")
    check = parser.parse_args().check
    stale = []
    for name, data in desired_files().items():
        path = ROOT / name
        source = VENDORS.get(name)
        current = path.read_bytes() if path.is_file() else None
        source_mode = (ROOT / source).stat().st_mode & 0o777 if source else None
        same_mode = source_mode is None or path.is_file() and path.stat().st_mode & 0o777 == source_mode
        if current == data and same_mode:
            continue
        stale.append(name)
        if not check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            if source_mode is not None:
                path.chmod(source_mode)
    if stale:
        print(("Package drift in " if check else "Synced ") + ", ".join(stale))
    return int(check and bool(stale))


if __name__ == "__main__":
    raise SystemExit(main())
