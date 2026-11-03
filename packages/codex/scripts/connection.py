#!/usr/bin/env python3
"""Configure nonsecret connection references and admit verified bundled MCP startup."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import runpy
import stat
import sys
import tempfile
from urllib.parse import urlsplit


PACKAGE = Path(__file__).resolve().parents[1]
CAPTURE = runpy.run_path(
    str(PACKAGE / "skills/commit-capture/scripts/lib/capture-owner.py")
)
BOOTSTRAP = runpy.run_path(str(PACKAGE / "skills/setup/scripts/bootstrap-runtime.py"))
PLUGIN = "obsidian@nhangen-codex-plugins"
NAME = "obsidian-connection.json"


class ConnectionError(Exception):
    pass


def fail(message):
    raise ConnectionError(message)


def absolute(value):
    if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
        fail("absolute path required")
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        fail("absolute path required")
    return path


def home():
    value = os.environ.get("CODEX_HOME")
    if value is None:
        value = str(absolute(os.environ.get("HOME")) / ".codex")
    path = absolute(value)
    CAPTURE["codex_verifier"]()["validate_path_ancestors"](path, "Codex home")
    if path.exists():
        item = path.stat()
        if (
            not stat.S_ISDIR(item.st_mode)
            or item.st_uid != os.getuid()
            or item.st_mode & 0o022
        ):
            fail("Codex home must be an owned, non-writable directory")
    return path


def credential(value):
    if not isinstance(value, dict):
        fail("credential reference required")
    provider = value.get("provider")
    if provider == "file" and set(value) == {"provider", "path"}:
        path = absolute(value["path"])
        CAPTURE["codex_verifier"]()["validate_path_ancestors"](
            path, "credential reference"
        )
        item = path.lstat()
        if (
            not stat.S_ISREG(item.st_mode)
            or item.st_nlink != 1
            or item.st_uid != os.getuid()
            or stat.S_IMODE(item.st_mode) not in (0o400, 0o600)
        ):
            fail("credential file must be owned, single-link, mode 0400 or 0600")
    elif provider == "keychain" and set(value) == {"provider", "service", "account"}:
        if sys.platform != "darwin":
            fail("keychain references require macOS")
        if any(
            not isinstance(value[k], str)
            or not value[k]
            or any(ord(c) < 32 or ord(c) == 127 for c in value[k])
            for k in ("service", "account")
        ):
            fail("invalid keychain reference")
    else:
        fail("unsupported credential reference; no provider fallback")
    return value


def validate(value):
    if (
        not isinstance(value, dict)
        or set(value)
        != {
            "schemaVersion",
            "runtimePrefix",
            "endpoint",
            "credentials",
            "allowHttp",
            "allowTailnetHttp",
        }
        or type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != 1
    ):
        fail("invalid connection schema")
    absolute(value["runtimePrefix"])
    for flag in ("allowHttp", "allowTailnetHttp"):
        if type(value[flag]) is not bool:
            fail("invalid HTTP policy")
    endpoint = value["endpoint"]
    if not isinstance(endpoint, str) or any(
        c.isspace() or ord(c) < 32 or ord(c) == 127 for c in endpoint
    ):
        fail("invalid endpoint")
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or "?" in endpoint
        or "#" in endpoint
    ):
        fail("endpoint must not contain credentials, query, or fragment")
    parsed.port
    if parsed.scheme == "http":
        loopback = parsed.hostname in ("localhost", "127.0.0.1", "::1")
        try:
            tailnet = ipaddress.ip_address(parsed.hostname) in ipaddress.ip_network(
                "100.64.0.0/10"
            )
        except ValueError:
            tailnet = parsed.hostname.endswith(".ts.net")
        if not value["allowHttp"] or not (
            loopback or tailnet and value["allowTailnetHttp"]
        ):
            fail("HTTP requires explicit loopback or tailnet authorization")
    if value["allowTailnetHttp"] and not value["allowHttp"]:
        fail("tailnet HTTP requires HTTP authorization")
    if not isinstance(value["credentials"], dict) or set(value["credentials"]) != {
        "read",
        "write",
    }:
        fail("both explicit credential profiles required")
    for reference in value["credentials"].values():
        credential(reference)
    if value["credentials"]["read"] == value["credentials"]["write"]:
        fail("read and write require distinct scoped credential references")
    return value


@contextmanager
def admitted(value):
    verifier = CAPTURE["codex_verifier"]()
    prefix = verifier["validate_prefix"](
        absolute(value["runtimePrefix"]), absolute(os.environ.get("HOME"))
    )
    verifier["validate_managed_directory"](prefix, "runtime prefix")
    verifier["validate_managed_directory"](prefix / "releases", "runtime releases")
    descriptor = os.open(
        prefix / ".install.lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    )
    try:
        item = os.fstat(descriptor)
        if (
            not stat.S_ISREG(item.st_mode)
            or item.st_uid != os.getuid()
            or item.st_nlink != 1
            or stat.S_IMODE(item.st_mode) != 0o600
        ):
            fail("unsafe runtime lock")
        fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        if (prefix / ".transition.json").exists() or (
            prefix / ".transition.json"
        ).is_symlink():
            fail("runtime transition pending; startup refused")
        slots = verifier["slot_map"](prefix, verify=False)
        if slots["current"] is None or slots["disabled"] is not None:
            fail("runtime is disabled or not installed; startup never installs")
        pin = BOOTSTRAP["read_pin"]()
        bundle = prefix / "releases" / slots["current"]
        CAPTURE["codex_verify"](
            {
                "bundle": str(bundle),
                "releaseId": pin["releaseId"],
                "externalReleaseSha256": pin["assets"][BOOTSTRAP["METADATA"]]["sha256"],
            }
        )
        yield bundle
    finally:
        os.close(descriptor)


def start(profile):
    if profile not in ("read", "write"):
        fail("unsupported connection profile; no fallback")
    value = validate(CAPTURE["read"](home() / NAME))
    with admitted(value) as bundle:
        env = {
            k: v
            for k, v in os.environ.items()
            if k in ("HOME", "PATH", "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME")
        }
        prefix = "OBSIDIAN_MCP_" + profile.upper()
        env[prefix + "_ENDPOINT"] = value["endpoint"]
        reference = credential(value["credentials"][profile])
        env[prefix + "_CREDENTIAL_PROVIDER"] = reference["provider"]
        if reference["provider"] == "file":
            env[prefix + "_TOKEN_FILE"] = reference["path"]
        else:
            env[prefix + "_KEYCHAIN_SERVICE"] = reference["service"]
            env[prefix + "_KEYCHAIN_ACCOUNT"] = reference["account"]
        if value["allowHttp"]:
            env["OBSIDIAN_MCP_ALLOW_HTTP"] = "1"
        if value["allowTailnetHttp"]:
            env["OBSIDIAN_MCP_ALLOW_TAILNET_HTTP"] = "1"
        os.execve(
            str(bundle / ("bin/obsidian-mcp-" + profile)),
            ["obsidian-mcp-" + profile],
            env,
        )


def routine_policy(config):
    import tomllib

    current = tomllib.loads(config.decode())
    plugin = current.get("plugins", {}).get(PLUGIN, {})
    default_enabled = (
        current.get("plugins", {}).get("_default", {}).get("enabled", True)
    )
    if (
        plugin.get("enabled", default_enabled) is False
        or current.get("features", {}).get("plugins") is False
    ):
        fail("plugin disabled; approval policy unchanged")
    if current.get("profile") is not None or current.get("profiles"):
        fail("profile policy requires separate review; no automatic policy edit")
    servers = plugin.get("mcp_servers", {})
    additions = []
    for name in ("obsidian", "obsidian-write"):
        if name in current.get("mcp_servers", {}):
            continue
        existing = servers.get(name)
        if existing is not None:
            if existing != {"default_tools_approval_mode": "auto"}:
                fail("existing plugin server policy conflicts; no policy relaxation")
        else:
            additions.append(
                f'\n[plugins."{PLUGIN}".mcp_servers."{name}"]\ndefault_tools_approval_mode = "auto"\n'
            )
    updated = config + "".join(additions).encode()
    tomllib.loads(updated.decode())
    return updated


def policy_bytes(path):
    if not path.exists() and not path.is_symlink():
        return b""
    item = path.lstat()
    if (
        not stat.S_ISREG(item.st_mode)
        or item.st_nlink != 1
        or item.st_uid != os.getuid()
        or item.st_mode & 0o077
    ):
        fail("config.toml must be an owned private single-link file")
    return BOOTSTRAP["regular_bytes"](path, 1024 * 1024)


def apply_config(destination, value, original, updated):
    record = destination / NAME
    policy = destination / "config.toml"
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(
        destination / ".obsidian-connection.lock",
        os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
        0o600,
    )
    try:
        item = os.fstat(descriptor)
        if (
            not stat.S_ISREG(item.st_mode)
            or item.st_nlink != 1
            or item.st_uid != os.getuid()
            or stat.S_IMODE(item.st_mode) != 0o600
        ):
            fail("unsafe connection lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if policy_bytes(policy) != original:
            fail("host policy changed; refusing overwrite")
        if record.exists() or record.is_symlink():
            if CAPTURE["read"](record) != value:
                fail("connection config changed; refusing overwrite")
        else:
            CAPTURE["write"](record, value)
        if updated != original:
            handle, temporary = tempfile.mkstemp(dir=destination)
            try:
                with os.fdopen(handle, "wb") as stream:
                    stream.write(updated)
                    stream.flush()
                    os.fsync(stream.fileno())
                if policy_bytes(policy) != original:
                    fail("host policy changed; refusing overwrite")
                os.replace(temporary, policy)
                directory = os.open(destination, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                Path(temporary).unlink(missing_ok=True)
    finally:
        os.close(descriptor)


def setup(args):
    references = {}
    for profile in ("read", "write"):
        file = getattr(args, profile + "_token_file")
        service = getattr(args, profile + "_keychain_service")
        account = getattr(args, profile + "_keychain_account")
        if file and not service and not account:
            references[profile] = {"provider": "file", "path": file}
        elif not file and service and account:
            references[profile] = {
                "provider": "keychain",
                "service": service,
                "account": account,
            }
        else:
            fail("choose exactly one complete credential reference per profile")
    value = validate(
        {
            "schemaVersion": 1,
            "runtimePrefix": args.runtime_prefix,
            "endpoint": args.endpoint,
            "credentials": references,
            "allowHttp": args.allow_http,
            "allowTailnetHttp": args.allow_tailnet_http,
        }
    )
    destination = home()
    record = destination / NAME
    policy = destination / "config.toml"
    if record.exists() or record.is_symlink():
        if CAPTURE["read"](record) != value:
            fail("connection config differs; refusing overwrite")
    original = policy_bytes(policy)
    updated = routine_policy(original) if args.authorize_routine_tools else original
    with admitted(value):
        if args.apply:
            apply_config(destination, value, original, updated)
    print(
        json.dumps(
            {
                "status": "configured" if args.apply else "preview",
                "connectionConfig": str(record),
                "routinePolicyChanged": updated != original,
                "captureActivation": "unchanged",
            }
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for profile in ("read", "write"):
        commands.add_parser(profile)
    configure = commands.add_parser("setup")
    configure.add_argument("--runtime-prefix", required=True)
    configure.add_argument("--endpoint", required=True)
    for profile in ("read", "write"):
        configure.add_argument("--" + profile + "-token-file")
        configure.add_argument("--" + profile + "-keychain-service")
        configure.add_argument("--" + profile + "-keychain-account")
    configure.add_argument("--allow-http", action="store_true")
    configure.add_argument("--allow-tailnet-http", action="store_true")
    configure.add_argument("--authorize-routine-tools", action="store_true")
    configure.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "setup":
            setup(args)
        else:
            start(args.command)
        return 0
    except ConnectionError as error:
        print("obsidian connection: " + str(error), file=sys.stderr)
        return 64
    except Exception:
        print(
            "obsidian connection: configuration, policy, or runtime verification failed; no fallback or installation",
            file=sys.stderr,
        )
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
