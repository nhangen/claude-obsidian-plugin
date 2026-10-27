#!/usr/bin/env python3
"""Register the public MCP client without changing capture ownership."""

import argparse
import copy
import fcntl
from fnmatch import fnmatchcase
import ipaddress
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from urllib.parse import urlsplit


class SetupError(Exception):
    pass


def load(path):
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise SetupError("symlinked configuration requires manual migration")
    if not path.exists():
        return None, {}
    if not path.is_file() or path.stat().st_uid != os.getuid():
        raise SetupError("configuration must be an owned regular file")
    raw = path.read_bytes()
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise SetupError("configuration must be a JSON object")
    return raw, value


def endpoint_policy(endpoint, allow_tailnet):
    if any(ord(char) <= 32 or ord(char) == 127 for char in endpoint):
        raise SetupError("invalid endpoint")
    url = urlsplit(endpoint)
    if (not url.hostname or url.username or url.password or url.query
            or url.fragment or url.scheme not in ("https", "http")):
        raise SetupError("invalid endpoint")
    _ = url.port
    if url.scheme == "https":
        return {}
    if not allow_tailnet:
        raise SetupError("HTTP requires --allow-tailnet-http")
    host = url.hostname
    try:
        tailnet = ipaddress.ip_address(host) in ipaddress.ip_network("100.64.0.0/10")
    except ValueError:
        tailnet = host.endswith(".ts.net")
    if not tailnet:
        raise SetupError("HTTP is restricted to tailnet endpoints")
    return {"OBSIDIAN_MCP_ALLOW_HTTP": "1", "OBSIDIAN_MCP_ALLOW_TAILNET_HTTP": "1"}


def plan(args, home):
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        raise SetupError("custom CLAUDE_CONFIG_DIR requires manual setup")
    client = Path(args.client_dir).expanduser().absolute()
    transport = endpoint_policy(args.endpoint, args.allow_tailnet_http)
    paths = (home / ".claude.json", home / ".claude/settings.json")
    originals, values = zip(*(load(path) for path in paths))
    config, settings = copy.deepcopy(values)
    servers = config.setdefault("mcpServers", {})
    permissions = settings.setdefault("permissions", {})
    if not isinstance(servers, dict) or not isinstance(permissions, dict):
        raise SetupError("invalid MCP or permission configuration")
    allowed = permissions.setdefault("allow", [])
    if not isinstance(allowed, list) or not all(isinstance(rule, str) for rule in allowed):
        raise SetupError("invalid permission allow list")
    tools = ("obsidian_keeper_save", "obsidian_daily_append")
    for field in ("deny", "ask"):
        rules = permissions.get(field, [])
        if not isinstance(rules, list) or not all(isinstance(rule, str) for rule in rules):
            raise SetupError("invalid permission list")
        if any(rule == "mcp__obsidian-write" or fnmatchcase(f"mcp__obsidian-write__{tool}", rule)
               for rule in rules for tool in tools):
            raise SetupError("existing permission policy prevents automatic routine writes")
    for profile, name in (("read", "obsidian"), ("write", "obsidian-write")):
        launcher = client / "bin" / f"obsidian-mcp-{profile}"
        if not launcher.is_file() or not os.access(launcher, os.X_OK):
            raise SetupError("install the verified public client before setup")
        upper = profile.upper()
        prefix = f"OBSIDIAN_MCP_{upper}"
        token_file = getattr(args, f"{profile}_token_file")
        env = {f"{prefix}_ENDPOINT": args.endpoint, **transport}
        if token_file:
            token_path = Path(token_file).expanduser().absolute()
            info = token_path.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) not in (0o400, 0o600)):
                raise SetupError("credential files must be owned regular files, mode 0400 or 0600")
            env.update({f"{prefix}_CREDENTIAL_PROVIDER": "file", f"{prefix}_TOKEN_FILE": str(token_path)})
        else:
            env.update({f"{prefix}_CREDENTIAL_PROVIDER": "env", f"{prefix}_TOKEN_ENV": f"{prefix}_TOKEN"})
        entry = {"command": str(launcher), "args": [], "env": env}
        if name in servers and servers[name] != entry:
            raise SetupError("existing Obsidian registration differs; inspect and migrate it explicitly")
        servers[name] = entry
    for tool in tools:
        rule = f"mcp__obsidian-write__{tool}"
        if rule not in allowed:
            allowed.append(rule)
    return [(path, before, (json.dumps(after, indent=2) + "\n").encode())
            for path, before, after in zip(paths, originals, (config, settings))
            if before is None or json.loads(before) != after]


def apply(changes):
    completed = []
    for path, before, after in changes:
        current, _ = load(path)
        if current != before:
            raise SetupError("configuration changed during setup; inspect and retry")
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if before is not None:
            fd, _ = tempfile.mkstemp(prefix=path.name + ".bak.", dir=path.parent)
            with os.fdopen(fd, "wb") as stream:
                stream.write(before)
                stream.flush()
                os.fsync(stream.fileno())
        fd, staged = tempfile.mkstemp(prefix=path.name + ".setup.", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(after)
                stream.flush()
                os.fsync(stream.fileno())
            current, _ = load(path)
            if current != before:
                raise SetupError("configuration changed during setup; inspect and retry")
            os.replace(staged, path)
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            completed.append(path)
        finally:
            if os.path.exists(staged):
                os.unlink(staged)
    return completed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client-dir", required=True, help="verified public client current directory")
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--read-token-file")
    parser.add_argument("--write-token-file")
    parser.add_argument("--allow-tailnet-http", action="store_true")
    parser.add_argument("--apply", action="store_true", help="otherwise preview only")
    args = parser.parse_args()
    try:
        if not os.environ.get("HOME"):
            raise SetupError("HOME must be set and nonempty")
        home = Path(os.environ["HOME"]).resolve(strict=True)
        changes = plan(args, home)
        if args.apply:
            lock = home / ".obsidian-mcp-setup.lock"
            fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "r+") as stream:
                fcntl.flock(stream, fcntl.LOCK_EX)
                changes = plan(args, home)
                apply(changes)
        print(json.dumps({"applied": args.apply, "changed_files": len(changes),
                          "capture_writer": "unchanged", "connection_verified": False}))
        return 0
    except (SetupError, OSError, ValueError, TypeError):
        print("obsidian-mcp-setup: incomplete; configuration or prerequisites rejected. "
              "No writer handoff performed. Inspect configuration/backups before retrying.", file=sys.stderr)
        return 64


if __name__ == "__main__":
    sys.exit(main())
