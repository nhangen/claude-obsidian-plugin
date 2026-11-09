#!/usr/bin/env python3
"""Host-local writer admission and delegation to the public capture runtime."""

import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time

HOOK_INPUT = {}


class OwnershipError(ValueError):
    pass


class CaptureUnavailable(OwnershipError):
    pass


def canonical_path(path, strict=False):
    try:
        return Path(path).resolve(strict=strict)
    except (OSError, RuntimeError) as error:
        raise OwnershipError(
            "cannot resolve canonical capture path; no fallback"
        ) from error


def root():
    home = os.environ.get("XDG_STATE_HOME")
    if home is not None:
        if not home or not Path(home).is_absolute():
            raise OwnershipError("XDG_STATE_HOME must be a nonempty absolute path")
    else:
        base = os.environ.get("HOME")
        if not base or not Path(base).is_absolute():
            raise OwnershipError("HOME must be a nonempty absolute path")
        home = str(Path(base) / ".local/state")
    return Path(home) / "claude-obsidian"


def directory(path):
    base = root()
    components = [base]
    for part in path.relative_to(base).parts:
        components.append(components[-1] / part)
    for component in components:
        component.mkdir(parents=True, mode=0o700, exist_ok=True)
        info = component.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise OwnershipError("unsafe capture state directory")
        component.chmod(0o700)
    return path


def unique_fields(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON field")
        value[key] = item
    return value


def decode_json(data):
    return json.loads(data, object_pairs_hook=unique_fields)


def read(path, budget=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor) as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
            or info.st_nlink != 1
            or info.st_size > 1048576
        ):
            raise OwnershipError("unsafe capture state file")
        if budget is not None:
            limit = min(info.st_size, budget[0])
            data = stream.buffer.read(limit + 1)
            if len(data) > limit:
                raise OwnershipError("Codex ownership inventory exceeds byte limit")
            budget[0] -= len(data)
            return decode_json(data)
        return json.load(stream, object_pairs_hook=unique_fields)


def write(path, value):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        Path(temporary).unlink(missing_ok=True)


def state_path():
    return directory(root() / "capture-ownership")


def ownership(read_only=False):
    try:
        path = root() / "capture-ownership" if read_only else state_path()
        value = read(path / "owner.json")
    except FileNotFoundError:
        return dict(schema=1, owner="legacy", phase="stable", generation=0, profiles={})
    if (
        not isinstance(value, dict)
        or value.get("schema") != 1
        or value.get("owner") not in ("legacy", "mcp", "disabled")
        or value.get("phase") not in ("stable", "draining")
        or type(value.get("generation")) is not int
        or not isinstance(value.get("profiles"), dict)
        or (
            "default_profile" in value
            and (
                not isinstance(value["default_profile"], str)
                or not value["default_profile"]
            )
        )
        or not isinstance(value.get("excluded_projects", []), list)
        or any(
            not isinstance(p, str) or not p for p in value.get("excluded_projects", [])
        )
    ):
        raise OwnershipError("invalid writer ownership record; admission closed")
    return value


def lease_valid():
    try:
        descriptor = int(os.environ["OBSIDIAN_CAPTURE_LEASE_FD"])
        info = os.fstat(descriptor)
        expected = (state_path() / "admission.lock").stat()
        return (info.st_dev, info.st_ino) == (expected.st_dev, expected.st_ino)
    except (KeyError, ValueError, OSError):
        return False


@contextlib.contextmanager
def admission(exclusive=False):
    if not exclusive and lease_valid():
        yield int(os.environ["OBSIDIAN_CAPTURE_LEASE_FD"])
        return
    descriptor = os.open(
        state_path() / "admission.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600
    )
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
        ):
            raise OwnershipError("unsafe admission lock")
        try:
            fcntl.flock(
                descriptor,
                (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB,
            )
        except BlockingIOError as error:
            raise OwnershipError(
                "writer admission busy; wait for active capture commands"
            ) from error
        os.set_inheritable(descriptor, True)
        yield descriptor
    finally:
        os.close(descriptor)


def execute(command, descriptor, payload=None):
    env = dict(os.environ, OBSIDIAN_CAPTURE_LEASE_FD=str(descriptor))
    return subprocess.run(
        command, input=payload, env=env, pass_fds=(descriptor,), check=False
    ).returncode


def legacy(command, payload=None, host=None):
    with admission() as descriptor:
        if host == "codex" and codex_record(codex_home()) is not None:
            raise OwnershipError(
                "Codex local write refused: activation record exists; no legacy fallback"
            )
        current = ownership()
        if current["phase"] != "stable" or current["owner"] != "legacy":
            raise OwnershipError(
                "local write refused: writer owner is "
                + current["owner"]
                + "/"
                + current["phase"]
                + "; use the configured MCP route, no local fallback"
            )
        check_exclusion(current, os.getcwd())
        keeper = len(command) > 2 and Path(command[1]).name == "keeper-core"
        if keeper:
            record = keeper_commit(command[2:])
            if record is not None:
                commit_record(record)
                command = [*command[:2], *record.arguments]
        result = execute(command, descriptor, payload)
        if result == 0 and keeper:
            acknowledge_commit(command[2:])
        return result


def keeper_commit(arguments):
    if arguments[:1] != ["append"]:
        return None
    options = {}
    names = {
        "--vault",
        "--target",
        "--date",
        "--section",
        "--body-file",
        "--init-file",
        "--skip-if-hash",
        "--request-id",
        "--idempotency-key",
        "--format",
    }
    for index in range(1, len(arguments), 2):
        name = arguments[index]
        if name not in names or index + 1 >= len(arguments):
            raise OwnershipError("invalid keeper append arguments")
        if name in options:
            raise OwnershipError("duplicate keeper append option: " + name)
        options[name] = arguments[index + 1]
    commit = options.get("--skip-if-hash", "")
    if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", commit):
        return None
    vault = options.get("--vault", "")
    if not vault:
        try:
            configured = subprocess.run(
                [
                    "bash",
                    "-c",
                    '. "$1"; obsidian_config_value vault_path "$2"',
                    "capture-identity",
                    str(Path(__file__).parent / "resolve-config.sh"),
                    str(Path(__file__).parent.parent),
                ],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            raise OwnershipError(
                "configured capture vault could not be resolved"
            ) from None
        if configured.returncode != 0:
            raise OwnershipError("full-hash capture requires a resolved vault")
        vault = configured.stdout.rstrip("\n")
    if not vault or not Path(vault).is_dir():
        raise OwnershipError("full-hash capture requires an existing vault")
    target = options.get("--target", "")
    date = options.get("--date", "")
    if target and date:
        raise OwnershipError("capture requires --target or --date, not both")
    target = target or ("Daily/" + date + ".md" if date else "")
    if not target:
        raise OwnershipError("full-hash capture requires --target or --date")
    vault = str(canonical_path(vault))
    target = str(Path(target))
    effective = ["append"]
    for name, value in options.items():
        if name not in ("--vault", "--target", "--date"):
            effective.extend((name, value))
    effective.extend(("--vault", vault, "--target", target))
    return argparse.Namespace(
        commit=commit.lower(), vault=vault, target=target, arguments=effective
    )


def commit_record(args):
    if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", args.commit or ""):
        raise OwnershipError("full commit hash required")
    target = Path(args.target)
    if target.is_absolute() or ".." in target.parts:
        raise OwnershipError("vault-relative commit target required")
    value = dict(
        hash=args.commit.lower(),
        vault=str(canonical_path(args.vault)),
        target=str(target),
    )
    key = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
    with admission():
        current = ownership()
        if current["owner"] != "legacy" or current["phase"] != "stable":
            raise OwnershipError("legacy commit ownership changed")
        check_exclusion(current, os.getcwd())
        path = directory(state_path() / "pending-commits") / (key + ".json")
        try:
            previous = read(path)
        except FileNotFoundError:
            previous = None
        if previous is not None:
            if not isinstance(previous, dict) or any(
                previous.get(k) != v for k, v in value.items()
            ):
                raise OwnershipError("invalid pending commit identity")
            if not resolved(path):
                return
        if resolution_path(path).exists():
            value["attempt_id"] = os.urandom(16).hex()
        write(path, value)


def acknowledge_commit(arguments):
    record = keeper_commit(arguments)
    if record is None:
        return
    pending = state_path() / "pending-commits"
    if not pending.exists():
        return
    for path in pending.glob("*.json"):
        value = read(path)
        if (
            value["hash"] != record.commit
            or value["target"] != str(Path(record.target))
            or value["vault"] != str(canonical_path(record.vault))
        ):
            continue
        note = Path(value["vault"]) / value["target"]
        try:
            verified = subprocess.run(
                [
                    "bash",
                    str(Path(__file__).parent.parent / "keeper-core"),
                    "has-commit-heading",
                    str(note),
                    value["hash"],
                ],
                capture_output=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            raise OwnershipError("commit heading readback failed") from None
        if verified.returncode != 0:
            raise OwnershipError("keeper succeeded but commit heading readback failed")
        archive = directory(state_path() / "acknowledged-commits")
        os.replace(path, archive / path.name)


def public_profile(profile):
    home = Path(profile)
    if not home.is_absolute() or home != canonical_path(home):
        raise OwnershipError("profile must be an absolute canonical path")
    config = read(home / "capture-profile.json")
    if (
        not isinstance(config, dict)
        or config.get("host") != "claude-plugin"
        or config.get("active") is not True
    ):
        raise OwnershipError("active public claude-plugin profile required")
    scope = config.get("scope", "project")
    if scope not in ("project", "user") or not isinstance(scope, str):
        raise OwnershipError("invalid public capture scope")
    if scope == "user":
        if config.get("project") is not None or "projectMode" in config:
            raise OwnershipError("user capture profile must not declare a project")
    else:
        mode = config.get("projectMode", "git")
        if not isinstance(mode, str) or mode not in ("git", "directory"):
            raise OwnershipError("invalid public capture project mode")
    return config


def operation_timeout(deadline, maximum):
    if deadline is None:
        return maximum
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise OwnershipError(
            "public capture exceeded its bounded hook budget; no fallback"
        )
    return min(remaining, maximum)


def public_command(profile, operation, deadline=None):
    config = public_profile(profile)
    bundle = Path(config.get("bundle", ""))
    executable = bundle / "bin/obsidian-mcp-native"
    if not bundle.is_absolute() or not executable.is_file():
        raise OwnershipError("public capture runtime unavailable; no fallback")
    user_scope = config.get("scope", "project") == "user"
    if user_scope or config.get("projectMode", "git") == "directory":
        capability = subprocess.run(
            [
                sys.executable,
                str(executable),
                "capabilities",
                "--release-sha256",
                config.get("releaseSha256", ""),
            ],
            capture_output=True,
            timeout=operation_timeout(deadline, 5),
            check=False,
        )
        capability_name = "user-scope" if user_scope else "directory"
        if capability.returncode or len(capability.stdout) > 262144:
            raise OwnershipError(
                "public runtime does not advertise " + capability_name + " capture"
            )
        advertised = decode_json(capability.stdout)
        modes = (
            advertised.get("captureScopes" if user_scope else "projectModes")
            if isinstance(advertised, dict)
            else None
        )
        supported = modes.get("claude-plugin") if isinstance(modes, dict) else None
        hosts = advertised.get("hosts") if isinstance(advertised, dict) else None
        if (
            not isinstance(advertised, dict)
            or type(advertised.get("apiVersion")) is not int
            or advertised["apiVersion"] != 1
            or not isinstance(hosts, list)
            or "claude-plugin" not in hosts
            or not isinstance(supported, list)
            or ("user" if user_scope else "directory") not in supported
        ):
            raise OwnershipError(
                "public runtime does not advertise " + capability_name + " capture"
            )
    return [sys.executable, str(executable), operation, "--home", str(profile)]


def public_drained(profile):
    result = subprocess.run(
        public_command(profile, "drain-status"),
        capture_output=True,
        check=False,
        timeout=30,
    )
    if result.returncode or decode_json(result.stdout).get("quiescent") is not True:
        raise OwnershipError(
            "public capture has pending or unverified work; admission remains closed"
        )


def public_hook(profile, descriptor, value, event, deadline):
    env = dict(os.environ, OBSIDIAN_CAPTURE_LEASE_FD=str(descriptor))
    try:
        result = subprocess.run(
            public_command(profile, "hook", deadline),
            input=json.dumps(value).encode(),
            capture_output=True,
            env=env,
            pass_fds=(descriptor,),
            timeout=operation_timeout(deadline, 8),
            check=False,
        )
    except subprocess.SubprocessError as error:
        raise OwnershipError(
            "public capture runtime did not complete; pending state retained, no fallback"
        ) from error
    if result.returncode or len(result.stdout) > 262144:
        raise OwnershipError(
            "public capture runtime failed; inspect its pinned release/profile and pending state, no fallback"
        )
    try:
        output = decode_json(result.stdout)
    except ValueError as error:
        raise OwnershipError(
            "public capture runtime returned an invalid hook response; no fallback"
        ) from error
    allowed = {
        "hookSpecificOutput",
        "decision",
        "reason",
        "systemMessage",
        "continue",
        "stopReason",
        "suppressOutput",
    }
    if not isinstance(output, dict) or set(output) - allowed:
        raise OwnershipError(
            "public capture runtime returned an invalid hook response; no fallback"
        )
    if "hookSpecificOutput" in output:
        specific = output["hookSpecificOutput"]
        if not isinstance(specific, dict) or specific.get("hookEventName") != event:
            raise OwnershipError(
                "public capture runtime returned the wrong hook event; no fallback"
            )
        if (
            set(specific)
            - {
                "hookEventName",
                "additionalContext",
                "permissionDecision",
                "permissionDecisionReason",
                "updatedInput",
            }
            or any(
                not isinstance(specific[key], str)
                for key in ("additionalContext", "permissionDecisionReason")
                if key in specific
            )
            or (
                "permissionDecision" in specific
                and (
                    event != "PreToolUse"
                    or specific["permissionDecision"] not in ("allow", "deny")
                )
            )
            or (
                "updatedInput" in specific
                and (
                    event != "PreToolUse"
                    or not isinstance(specific["updatedInput"], dict)
                    or not isinstance(specific["updatedInput"].get("command"), str)
                )
            )
        ):
            raise OwnershipError(
                "public capture runtime returned an invalid event payload; no fallback"
            )
    if "decision" in output and (
        output["decision"] != "block" or not isinstance(output.get("reason"), str)
    ):
        raise OwnershipError(
            "public capture runtime returned an invalid hook decision; no fallback"
        )
    if event == "UserPromptSubmit" and (
        output.get("decision") == "block" or output.get("continue") is False
    ):
        output = dict(
            hookSpecificOutput=dict(
                hookEventName=event,
                additionalContext=str(
                    output.get("reason")
                    or output.get("stopReason")
                    or "Obsidian capture unavailable; ordinary work may continue."
                ),
            )
        )
    print(json.dumps(output))
    return 0


def resolution_path(path):
    key = hashlib.sha256(str(path.relative_to(root())).encode()).hexdigest()
    return root() / "capture-ownership/resolutions" / (key + ".json")


def resolved(path, digest=None, read_record=read):
    try:
        record = read_record(resolution_path(path))
    except FileNotFoundError:
        return False
    return isinstance(record, dict) and record.get("sha256") == (
        digest if digest is not None else evidence_digest(path)
    )


def evidence_bytes(path, private=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_size > 1048576
            or (private and info.st_mode & 0o077)
        ):
            raise OwnershipError("unsafe legacy evidence file")
        data = stream.read(1048577)
        if len(data) > 1048576:
            raise OwnershipError("legacy evidence exceeds bounded inspection")
        return data


def evidence_digest(path):
    return hashlib.sha256(evidence_bytes(path)).hexdigest()


def resolve_legacy(args):
    if (
        args.verification != "authoritative-vault-and-history-inspected"
        or not args.reason
    ):
        raise OwnershipError(
            "inspect the authoritative vault and Git history and supply a resolution reason"
        )
    relative = Path(args.evidence or "")
    if relative.is_absolute() or ".." in relative.parts or len(relative.parts) < 2:
        raise OwnershipError("a specific relative evidence file is required")
    if relative.parts[0] not in (
        "pre-commit-head",
        "pre-commit-processing",
        "session-capture",
        "capture-ownership",
    ):
        raise OwnershipError("not a legacy capture evidence path")
    if (
        relative.parts[0] == "capture-ownership"
        and relative.parts[1] != "pending-commits"
    ):
        raise OwnershipError("not a pending legacy commit evidence path")
    path = root() / relative
    if (
        not path.is_file()
        or path.is_symlink()
        or canonical_path(root()) not in canonical_path(path).parents
    ):
        raise OwnershipError("unsafe evidence path")
    with admission(exclusive=True):
        digest = evidence_digest(path)
        if args.evidence_sha256 is not None and (
            not hash_value(args.evidence_sha256) or args.evidence_sha256 != digest
        ):
            raise OwnershipError(
                "legacy evidence changed since inspection; inspect again before resolving"
            )
        key = hashlib.sha256(str(relative).encode()).hexdigest()
        record = dict(
            evidence=str(relative),
            sha256=digest,
            verification=args.verification,
            reason=args.reason,
            status="operator_resolved_not_mcp_receipt",
        )
        write(directory(state_path() / "resolutions") / (key + ".json"), record)
        return record


def finite_timestamp(value):
    try:
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def hash_value(value, lengths=(64,)):
    return (
        isinstance(value, str)
        and len(value) in lengths
        and bool(re.fullmatch(r"[0-9a-f]+", value))
    )


def checkpoint_schema(value):
    return (
        isinstance(value, dict)
        and set(value) == {"version", "seen", "git", "head", "last_attempt"}
        and type(value["version"]) is int
        and value["version"] == 1
        and isinstance(value["seen"], list)
        and all(hash_value(item) for item in value["seen"])
        and (value["git"] is None or hash_value(value["git"]))
        and (value["head"] is None or hash_value(value["head"], (40, 64)))
        and finite_timestamp(value["last_attempt"])
    )


def activity_status(value):
    if not isinstance(value, dict):
        return "invalid_activity"
    if "pending" in value:
        pending = value["pending"]
        if not isinstance(pending, list) or not all(hash_value(fp) for fp in pending):
            return "invalid_activity"
        if pending:
            return "pending_activity"
        checkpoint = {key: item for key, item in value.items() if key != "pending"}
        if checkpoint_schema(checkpoint) or (
            set(checkpoint) <= {"last_attempt"}
            and (not checkpoint or finite_timestamp(checkpoint["last_attempt"]))
        ):
            return "activity_clear"
        return "invalid_activity"
    return (
        "legacy_checkpoint_history" if checkpoint_schema(value) else "invalid_activity"
    )


def terminal_receipt(value):
    return (
        isinstance(value, dict)
        and value.get("status") == "process_succeeded"
        and value.get("retry_required") is False
        and type(value.get("exit_code")) is int
        and value["exit_code"] == 0
        and value.get("ack") == "acknowledged"
    )


def corroborates_checkpoint(path, value, checkpoint):
    return (
        terminal_receipt(value)
        and type(value.get("schema_version")) is int
        and value["schema_version"] == 1
        and hash_value(value.get("source_session_hash"))
        and value["source_session_hash"] == path.parent.parent.name
        and hash_value(value.get("boundary"))
        and value["boundary"] == path.stem
        and finite_timestamp(value.get("time"))
        and finite_timestamp(value.get("finished_at"))
        and value["time"] <= checkpoint["last_attempt"] <= value["finished_at"]
    )


def existing_directory(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OwnershipError("unsafe legacy evidence directory")
    return True


def legacy_inspection():
    base = root()
    rows = []
    entries_seen = files_seen = bytes_seen = 0

    def entries(path):
        nonlocal entries_seen
        if not existing_directory(path):
            return []
        items = []
        for item in path.iterdir():
            entries_seen += 1
            if entries_seen > 4096:
                raise OwnershipError("legacy inspection exceeds 4096 directory entries")
            items.append(item)
        return sorted(items)

    def content(path, private=False):
        nonlocal files_seen, bytes_seen
        files_seen += 1
        if files_seen > 2048:
            raise OwnershipError("legacy inspection exceeds 2048 evidence files")
        data = evidence_bytes(path, private)
        bytes_seen += len(data)
        if bytes_seen > 16 * 1024 * 1024:
            raise OwnershipError("legacy inspection exceeds 16 MiB of evidence")
        return data, hashlib.sha256(data).hexdigest()

    def add(path, status, blocking=True, **details):
        rows.append(
            dict(
                path=str(path.relative_to(base)),
                status=status,
                blocking=blocking,
                **details,
            )
        )

    def read_resolution(path):
        data, _ = content(path, private=True)
        return decode_json(data)

    def record(path):
        details = {}
        try:
            data, digest = content(path, private=True)
            details["sha256"] = digest
            if resolved(path, digest, read_resolution):
                add(path, "operator_resolved", False, **details)
                return None
            value = decode_json(data)
            if value is None:
                add(path, "invalid_evidence", **details)
                return None
            return value, digest
        except OwnershipError:
            raise
        except (OSError, ValueError, TypeError):
            add(path, "invalid_evidence", **details)
            return None

    if not existing_directory(base):
        return rows
    if existing_directory(base / "capture-ownership"):
        existing_directory(base / "capture-ownership/resolutions")
    for folder in (
        "pre-commit-head",
        "pre-commit-processing",
        "capture-ownership/pending-commits",
    ):
        path = base / folder
        for item in entries(path):
            try:
                _, digest = content(item)
                reconciled = resolved(item, digest, read_resolution)
                add(
                    item,
                    "operator_resolved" if reconciled else "unresolved_commit",
                    not reconciled,
                    sha256=digest,
                )
            except OwnershipError:
                raise
            except (OSError, ValueError, TypeError):
                add(item, "invalid_evidence")
    captures = base / "session-capture"
    if not existing_directory(captures):
        return rows
    sessions = entries(captures)
    if len(sessions) > 256:
        raise OwnershipError("legacy inspection exceeds 256 sessions")
    for session in sessions:
        if not existing_directory(session):
            continue
        lock = session / "activity.lock"
        try:
            descriptor = os.open(lock, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            descriptor = None
        if descriptor is not None:
            try:
                info = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(info.st_mode)
                    or info.st_uid != os.getuid()
                    or info.st_mode & 0o077
                ):
                    raise OwnershipError("unsafe legacy worker lock")
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    _, digest = content(lock, private=True)
                    add(lock, "active_worker", sha256=digest)
            finally:
                os.close(descriptor)
        receipts = []
        for path in entries(session / "boundaries"):
            if path.suffix != ".json":
                continue
            result = record(path)
            if result is not None:
                value, digest = result
                receipts.append((path, value))
                terminal = terminal_receipt(value)
                add(
                    path,
                    "terminal_receipt" if terminal else "unresolved_receipt",
                    not terminal,
                    sha256=digest,
                )
        path = session / "activity.json"
        if path.exists() or path.is_symlink():
            result = record(path)
            if result is not None:
                value, digest = result
                status = activity_status(value)
                details = {}
                if status == "legacy_checkpoint_history":
                    details = dict(
                        delivery="indeterminate",
                        terminal_boundary_observed=any(
                            corroborates_checkpoint(receipt, result, value)
                            for receipt, result in receipts
                        ),
                    )
                add(path, status, status != "activity_clear", sha256=digest, **details)
        for path in entries(session / "launches"):
            if path.suffix != ".json":
                continue
            result = record(path)
            if result is not None:
                value, digest = result
                observed = isinstance(value, dict) and value.get("status") == "observed"
                add(
                    path,
                    "observed_launch" if observed else "unobserved_launch",
                    not observed,
                    sha256=digest,
                )
    return rows


def inspect_legacy():
    base = root()
    descriptor = None
    busy = False
    if existing_directory(base) and existing_directory(base / "capture-ownership"):
        try:
            descriptor = os.open(
                base / "capture-ownership/admission.lock",
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            )
        except FileNotFoundError:
            pass
    try:
        if descriptor is not None:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.getuid()
                or info.st_mode & 0o077
            ):
                raise OwnershipError("unsafe admission lock")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                busy = True
        current = ownership(read_only=True)
        rows = legacy_inspection()
        if busy:
            rows.append(
                dict(
                    path="capture-ownership/admission.lock",
                    status="active_writer",
                    blocking=True,
                    sha256=evidence_digest(base / "capture-ownership/admission.lock"),
                )
            )
        counts = {}
        for row in rows:
            counts[row["status"]] = counts.get(row["status"], 0) + 1
        blocking = sum(row["blocking"] for row in rows)
        result = dict(
            status="legacy_evidence_blocked" if blocking else "legacy_evidence_clear",
            scope="legacy_evidence_only",
            ready=not blocking,
            ownership=current,
            blocking_count=blocking,
            counts=counts,
            evidence=rows,
        )
        if len(json.dumps(result).encode()) > 1048576:
            raise OwnershipError("legacy inspection report exceeds 1 MiB")
        return result
    finally:
        if descriptor is not None:
            os.close(descriptor)


def legacy_drained():
    for row in legacy_inspection():
        if not row["blocking"]:
            continue
        if row["status"] == "unresolved_commit":
            message = "unresolved legacy commit evidence"
        elif row["status"] == "active_worker":
            message = "legacy background worker is still active"
        elif row["status"] == "unresolved_receipt":
            message = (
                "unresolved legacy session receipt; inspect retained session evidence"
            )
        elif row["status"] == "unobserved_launch":
            message = "unobserved legacy capture launch remains; inspect or retry the original source"
        else:
            message = "unsent or historical unverified legacy activity remains"
        raise OwnershipError(message + ": " + row["path"])


def reflog_digest(project):
    result = subprocess.run(
        ["git", "-C", project, "rev-parse", "--git-path", "logs/HEAD"],
        capture_output=True,
        text=True,
        check=True,
        timeout=5,
    )
    path = Path(result.stdout.strip())
    if not path.is_absolute():
        path = Path(project) / path
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 8 * 1024 * 1024:
            return None
        data = stream.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            return None
        return hashlib.sha256(data).hexdigest()


def transition(args):
    if args.verification != "legacy-writers-stopped-and-history-inspected":
        raise OwnershipError(
            "stop older clients/writers and inspect legacy history before handoff"
        )
    with admission(exclusive=True):
        current = ownership()
        current.update(phase="draining")
        write(state_path() / "owner.json", current)
        legacy_drained()
        codex_drain_all()
        profiles = dict(current["profiles"])
        for profile in set(profiles.values()) | (
            {current["default_profile"]} if current.get("default_profile") else set()
        ):
            public_drained(profile)
        if args.owner == "mcp":
            if not args.profile or (args.scope == "project" and not args.project):
                raise OwnershipError(
                    "MCP handoff requires project and attached public profile"
                )
            config = public_profile(args.profile)
            if args.scope == "user":
                if args.project or config.get("scope") != "user":
                    raise OwnershipError(
                        "user handoff requires a user-scope profile without project"
                    )
            else:
                project = str(canonical_path(args.project, strict=True))
                if (
                    config.get("scope", "project") != "project"
                    or config.get("project") != project
                ):
                    raise OwnershipError(
                        "profile project does not match handoff project"
                    )
            public_drained(args.profile)
            if args.scope == "user":
                current["default_profile"] = args.profile
            else:
                profiles[project] = args.profile
        if args.clear_exclusions or args.exclude_project:
            exclusions = (
                []
                if args.clear_exclusions
                else list(current.get("excluded_projects", []))
            )
            for value in args.exclude_project:
                path = canonical_path(value, strict=True)
                if not Path(value).is_absolute() or not path.is_dir():
                    raise OwnershipError(
                        "capture exclusion must be an absolute directory"
                    )
                if str(path) not in exclusions:
                    exclusions.append(str(path))
            current["excluded_projects"] = exclusions
        current.update(
            owner=args.owner,
            phase="stable",
            profiles=profiles,
            generation=current["generation"] + 1,
        )
        write(state_path() / "owner.json", current)
        return current


def resume():
    with admission(exclusive=True):
        current = ownership()
        if current["phase"] != "draining":
            raise OwnershipError("no interrupted handoff to resume")
        current.update(
            phase="stable",
            generation=current["generation"] + 1,
            last_transition="cancelled_without_owner_change",
        )
        write(state_path() / "owner.json", current)
        return current


def check_exclusion(current, cwd):
    if not current.get("excluded_projects"):
        return
    if not isinstance(cwd, str) or not cwd or not Path(cwd).is_absolute():
        raise OwnershipError("hook project identity unavailable")
    directory = canonical_path(cwd, strict=True)
    if not directory.is_dir():
        raise OwnershipError("hook project identity unavailable")
    for excluded in current.get("excluded_projects", []):
        path = Path(excluded)
        if not path.is_absolute() or str(canonical_path(path)) != excluded:
            raise OwnershipError("invalid canonical capture exclusion")
        if directory.is_relative_to(path):
            raise CaptureUnavailable(
                "Obsidian capture excluded for this workspace; no write or legacy fallback"
            )


def capture_profile(current, cwd, deadline):
    if not isinstance(cwd, str) or not cwd or not Path(cwd).is_absolute():
        raise OwnershipError("hook project identity unavailable")
    directory = canonical_path(cwd, strict=True)
    if not directory.is_dir():
        raise OwnershipError("hook project identity unavailable")
    check_exclusion(current, cwd)
    registrations = {}
    for registered, profile in current["profiles"].items():
        project = Path(registered)
        canonical = canonical_path(project)
        if (
            not project.is_absolute()
            or str(canonical) != registered
            or canonical in registrations
        ):
            raise OwnershipError("invalid canonical project registration")
        registrations[canonical] = profile
    matches = [
        project for project in registrations if directory.is_relative_to(project)
    ]
    if not matches:
        if current.get("default_profile"):
            profile = current["default_profile"]
            if public_profile(profile).get("scope") != "user":
                raise OwnershipError("default capture profile must have user scope")
            return profile
        raise CaptureUnavailable(
            "no MCP capture profile for this project; no legacy fallback"
        )
    project = max(matches, key=lambda candidate: len(candidate.parts))
    profile = registrations[project]
    config = public_profile(profile)
    if config.get("scope", "project") != "project" or config.get("project") != str(
        project
    ):
        raise OwnershipError(
            "public capture profile does not match its project registration"
        )
    if config.get("projectMode", "git") == "git":
        found = subprocess.run(
            ["git", "-C", str(directory), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
            timeout=operation_timeout(deadline, 5),
        )
        if found.returncode or str(
            canonical_path(found.stdout.strip(), strict=True)
        ) != str(project):
            raise OwnershipError("hook project is not the registered Git checkout")
    return profile


def route(event, fallback, arguments):
    global HOOK_INPUT
    payload = sys.stdin.buffer.read(262145)
    if len(payload) > 262144:
        raise OwnershipError("hook payload exceeds bounded input")
    deadline = time.monotonic() + 8
    try:
        HOOK_INPUT = decode_json(payload)
    except ValueError as error:
        raise OwnershipError(
            "hook input must be valid JSON without duplicate fields"
        ) from error
    if not isinstance(HOOK_INPUT, dict):
        raise OwnershipError("hook input must be a JSON object")
    with admission() as descriptor:
        current = ownership()
        if current["phase"] != "stable":
            raise OwnershipError("writer handoff unresolved; admission closed")
        if current["owner"] == "disabled":
            if event == "PreToolUse" and HOOK_INPUT.get("tool_name") in (
                "mcp__obsidian-write__obsidian_keeper_save",
                "mcp__obsidian-write__obsidian_daily_append",
            ):
                print(
                    json.dumps(
                        dict(
                            hookSpecificOutput=dict(
                                hookEventName=event,
                                permissionDecision="deny",
                                permissionDecisionReason="Obsidian writer ownership is disabled; no write attempted.",
                            )
                        )
                    )
                )
                return 0
            print(
                json.dumps(
                    dict(
                        systemMessage="Obsidian capture is disabled; no write attempted."
                    )
                )
            )
            return 0
        check_exclusion(current, HOOK_INPUT.get("cwd"))
        if current["owner"] == "legacy":
            if fallback:
                return execute(["bash", fallback, *arguments], descriptor, payload)
            print("{}")
            return 0
        value = decode_json(payload)
        profile = capture_profile(current, value.get("cwd"), deadline)
        value["hook_event_name"] = event
        return public_hook(profile, descriptor, value, event, deadline)


VERIFIER_SHA256 = "d3f1e9bb467587294431c7e41665b8a3fa987036cf7ca207a79ae1c4f4243e16"
VERIFIER_SIZE = 38431
CODEX_EVENTS = ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionStart")
CODEX_WRITES = (
    "mcp__obsidian_write__obsidian_keeper_save",
    "mcp__obsidian_write__obsidian_daily_append",
)
CODEX_VERIFICATION = "legacy-writers-stopped-and-history-inspected"
CODEX_BINDING_KEYS = (
    "profile",
    "bundle",
    "externalReleaseSha256",
    "releaseId",
    "python",
)


def codex_home(value=None):
    if value is None:
        value = os.environ.get("CODEX_HOME")
        if value is None:
            home = os.environ.get("HOME")
            if not home or not Path(home).is_absolute():
                raise OwnershipError("HOME must be a nonempty absolute path")
            value = str(Path(home) / ".codex")
    if not value or not Path(value).is_absolute():
        raise OwnershipError("CODEX_HOME must be a nonempty absolute path")
    home = str(canonical_path(value))
    matches = []
    for record in codex_inventory():
        try:
            same = Path(home).samefile(record["codex_home"])
        except FileNotFoundError:
            continue
        if same:
            matches.append(record["codex_home"])
    if len(matches) > 1:
        raise OwnershipError(
            "multiple Codex records identify the same physical home; admission closed"
        )
    return matches[0] if matches else home


def codex_path(home):
    key = hashlib.sha256(home.encode()).hexdigest()
    return root() / "capture-ownership/codex" / (key + ".json")


def codex_binding(value):
    if not isinstance(value, dict) or set(value) != {
        "profile",
        "bundle",
        "externalReleaseSha256",
        "releaseId",
        "python",
    }:
        raise OwnershipError("invalid retained Codex profile; admission closed")
    for key in ("profile", "bundle", "python"):
        path = value[key]
        if (
            not isinstance(path, str)
            or not Path(path).is_absolute()
            or str(canonical_path(path)) != path
        ):
            raise OwnershipError(
                "Codex profile and bundle must be canonical absolute paths"
            )
    for key in ("externalReleaseSha256", "releaseId"):
        if not isinstance(value[key], str) or not re.fullmatch(
            r"[0-9a-f]{64}", value[key]
        ):
            raise OwnershipError("invalid Codex release identity; admission closed")
    return value


def codex_record(home):
    base = root() / "capture-ownership"
    for path in (root(), base, base / "codex"):
        existing_directory(path)
    try:
        value = read(codex_path(home))
    except FileNotFoundError:
        return None
    return validate_codex_record(value, home)


def validate_codex_record(value, home):
    if (
        not isinstance(value, dict)
        or type(value.get("schema")) is not int
        or value["schema"] != 1
        or value.get("host") != "codex"
        or value.get("codex_home") != home
        or value.get("owner") not in ("mcp", "disabled")
        or value.get("delivery") not in ("plugin", "managed")
        or value.get("phase") not in ("stable", "draining")
        or type(value.get("generation")) is not int
        or value["generation"] < 0
        or not isinstance(value.get("retained_profiles"), list)
        or not 1 <= len(value["retained_profiles"]) <= 128
    ):
        raise OwnershipError("invalid Codex ownership record; admission closed")
    selected = codex_binding({key: value.get(key) for key in CODEX_BINDING_KEYS})
    retained = [codex_binding(item) for item in value["retained_profiles"]]
    if selected not in retained:
        raise OwnershipError("selected Codex profile missing from drain inventory")
    return value


def codex_inventory():
    base = root() / "capture-ownership"
    for path in (root(), base, base / "codex"):
        if not existing_directory(path):
            return []
    records = []
    budget = [8 * 1024 * 1024]
    for index, entry in enumerate((base / "codex").iterdir()):
        if index >= 1024:
            raise OwnershipError("Codex ownership inventory exceeds entry limit")
        value = read(entry, budget=budget)
        home = value.get("codex_home") if isinstance(value, dict) else None
        if (
            not isinstance(home, str)
            or not Path(home).is_absolute()
            or str(canonical_path(home)) != home
            or codex_path(home) != entry
        ):
            raise OwnershipError(
                "invalid Codex ownership inventory identity; admission closed"
            )
        records.append(validate_codex_record(value, home))
    return records


def codex_verifier():
    verifier = Path(__file__).resolve().with_name("obsidian-mcp-client-install")
    descriptor = os.open(verifier, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        data = stream.read(VERIFIER_SIZE + 1)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_size != VERIFIER_SIZE
        or hashlib.sha256(data).hexdigest() != VERIFIER_SHA256
    ):
        raise OwnershipError("published standalone verifier authentication failed")
    # Execute the authenticated bytes, so replacement after the read cannot change the verifier.
    namespace = {"__name__": "obsidian_published_verifier", "__file__": str(verifier)}
    exec(compile(data, str(verifier), "exec"), namespace)
    return namespace


def codex_verify(binding):
    bundle = Path(binding["bundle"])
    if not re.fullmatch(r"[0-9a-f]{64}", binding.get("externalReleaseSha256", "")):
        raise OwnershipError("external release SHA-256 required")
    namespace = codex_verifier()
    try:
        if (bundle / ".trust.json").exists() or (bundle / ".trust.json").is_symlink():
            if bundle.parent.name != "releases":
                raise OwnershipError(
                    "installed bundle must be a canonical managed release"
                )
            metadata = namespace["verify_installed_release"](
                bundle.parent.parent, bundle.name, binding["externalReleaseSha256"]
            )
        else:
            metadata = namespace["verify_source"](
                bundle, binding["externalReleaseSha256"]
            )[0]
    except namespace["InstallError"] as error:
        raise OwnershipError(
            "public bundle verification failed; no native execution"
        ) from error
    if (
        binding.get("releaseId") is not None
        and binding["releaseId"] != metadata["releaseId"]
    ):
        raise OwnershipError("Codex release ID mismatch")
    return metadata


def codex_native(
    binding, operation, *arguments, payload=None, descriptor=None, deadline=None
):
    codex_verify(binding)
    command = [
        binding["python"],
        "-I",
        "-B",
        str(Path(binding["bundle"]) / "bin/obsidian-mcp-native"),
        operation,
        *arguments,
    ]
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    if descriptor is not None:
        env["OBSIDIAN_CAPTURE_LEASE_FD"] = str(descriptor)
    result = subprocess.run(
        command,
        input=json.dumps(payload).encode() if payload is not None else None,
        capture_output=True,
        check=False,
        env=env,
        pass_fds=(descriptor,) if descriptor is not None else (),
        timeout=operation_timeout(deadline, 8 if operation == "hook" else 30),
    )
    if result.returncode or len(result.stdout) > 262144:
        if operation == "capabilities":
            raise OwnershipError(
                "unsupported public runtime: attached Codex capabilities unavailable"
            )
        raise OwnershipError(
            "Codex public runtime failed "
            + operation
            + "; pending evidence retained, no fallback"
        )
    value = decode_json(result.stdout)
    if not isinstance(value, dict):
        raise OwnershipError("invalid Codex public runtime response")
    return value


def codex_capabilities(binding, deadline=None):
    value = codex_native(
        binding,
        "capabilities",
        "--release-sha256",
        binding["externalReleaseSha256"],
        deadline=deadline,
    )
    if (
        type(value.get("apiVersion")) is not int
        or value["apiVersion"] != 1
        or "codex" not in value.get("hosts", [])
        or "user" not in value.get("captureScopes", {}).get("codex", [])
        or "user" not in value.get("attachedCaptureScopes", {}).get("codex", [])
        or not {"git", "directory"}.issubset(
            value.get("userWorkspaceModes", {}).get("codex", [])
        )
        or value.get("promptIdentities", {}).get("codex") != "native-turn-id"
        or not {
            "attach",
            "profile-status",
            "drain-status",
            "hook",
            "prepare",
            "retry",
            "request",
        }.issubset(value.get("operations", []))
        or value.get("release_id") != binding["releaseId"]
    ):
        raise OwnershipError(
            "unsupported public runtime: attached Codex user capture with native turn identity required"
        )


def codex_profile(binding, deadline=None):
    profile = Path(binding["profile"])
    existing_directory(profile)
    value = read(profile / "capture-profile.json")
    if isinstance(value, dict) and value.get("python") != binding["python"]:
        raise OwnershipError(
            "Codex profile Python does not match the trusted launcher; "
            "use the proper trusted launcher that created this profile, "
            "or attach a new profile with this launcher"
        )
    expected = dict(
        schemaVersion=1,
        host="codex",
        scope="user",
        profileMode="attached",
        active=True,
        files={},
        bundle=binding["bundle"],
        releaseSha256=binding["externalReleaseSha256"],
        releaseId=binding["releaseId"],
        python=binding["python"],
    )
    if (
        not isinstance(value, dict)
        or any(value.get(key) != item for key, item in expected.items())
        or any(
            key in value for key in ("project", "projectMode", "parentHome", "config")
        )
    ):
        raise OwnershipError(
            "active attached user-wide Codex profile does not match activation"
        )
    result = codex_native(
        binding, "profile-status", "--home", str(profile), deadline=deadline
    )
    if (
        result.get("status") != "validated"
        or result.get("apiVersion") != 1
        or result.get("release_id") != binding["releaseId"]
    ):
        raise OwnershipError("public Codex profile validation failed")


def codex_drained(binding):
    codex_capabilities(binding)
    codex_profile(binding)
    result = codex_native(binding, "drain-status", "--home", binding["profile"])
    if result.get("quiescent") is not True or result.get("complete") is not True:
        raise OwnershipError(
            "Codex capture has pending or unverified work; admission remains draining"
        )


def codex_drain_all():
    for record in codex_inventory():
        for binding in record["retained_profiles"]:
            codex_drained(binding)


def codex_require_global():
    value = ownership(read_only=True)
    if value["phase"] != "stable" or value["owner"] == "disabled":
        raise OwnershipError(
            "global writer ownership is "
            + value["owner"]
            + "/"
            + value["phase"]
            + "; Codex admission closed"
        )
    return value


def codex_separate_profile(profile, home):
    profile, home = Path(profile), Path(home)
    try:
        same = profile.samefile(home)
    except FileNotFoundError:
        same = False
    if same or profile == home or home.is_relative_to(profile):
        raise OwnershipError(
            "attached capture profile must be separate from CODEX_HOME"
        )


def codex_transition(args, home):
    current = codex_record(home)
    if args.operation == "codex-activate":
        if args.delivery != "plugin":
            raise OwnershipError(
                "managed activation requires a separately validated administrator installation"
            )
        if (
            not args.bundle
            or not args.profile
            or not args.release_sha256
            or not args.codex_home
        ):
            raise OwnershipError(
                "activation requires --bundle --release-sha256 --profile --codex-home"
            )
        candidate = dict(
            profile=str(canonical_path(args.profile)),
            bundle=str(canonical_path(args.bundle)),
            externalReleaseSha256=args.release_sha256,
            python=str(Path(sys.executable).resolve()),
        )
        if not Path(args.profile).is_absolute() or not Path(args.bundle).is_absolute():
            raise OwnershipError("absolute profile and bundle paths required")
        codex_separate_profile(candidate["profile"], home)
        candidate["releaseId"] = codex_verify(candidate)["releaseId"]
        previous_binding = (
            next(
                (
                    binding
                    for binding in current["retained_profiles"]
                    if binding["profile"] == candidate["profile"]
                ),
                None,
            )
            if current
            else None
        )
        if previous_binding:
            candidate["python"] = previous_binding["python"]
        if (
            Path(candidate["profile"]).exists()
            or Path(candidate["profile"]).is_symlink()
        ):
            codex_profile(candidate)
        elif not args.create_profile:
            raise OwnershipError(
                "new private profile requires explicit --create-profile"
            )
        elif not Path(candidate["profile"]).parent.is_dir():
            raise OwnershipError(
                "new private profile requires an existing canonical parent"
            )
        codex_capabilities(candidate)
    else:
        if current is None:
            raise OwnershipError("no Codex activation record to disable")
        candidate = {key: current[key] for key in CODEX_BINDING_KEYS}
    codex_require_global()
    if not args.apply:
        return dict(
            status="preview",
            codex_home=home,
            operation=args.operation,
            selected=candidate,
            create_profile=args.create_profile
            and not Path(candidate["profile"]).exists(),
            ownership_changed=False,
        )
    if args.verification != CODEX_VERIFICATION:
        raise OwnershipError(
            "stop or upgrade older writers and inspect legacy history; --verification "
            + CODEX_VERIFICATION
            + " required"
        )
    with admission(exclusive=True):
        home = codex_home(home)
        codex_separate_profile(candidate["profile"], home)
        codex_require_global()
        current = codex_record(home)
        retained = list(current["retained_profiles"]) if current else []
        if candidate not in retained:
            retained.append(candidate)
        if len(retained) > 128:
            raise OwnershipError("Codex retained profile limit reached")
        record = dict(
            schema=1,
            host="codex",
            codex_home=home,
            owner=current["owner"] if current else "disabled",
            delivery=current["delivery"] if current else "plugin",
            phase="draining",
            generation=current["generation"] if current else 0,
            retained_profiles=retained,
            **candidate,
        )
        path = codex_path(home)
        directory(path.parent)
        write(path, record)
        legacy_drained()
        if not Path(candidate["profile"]).exists():
            if args.operation != "codex-activate" or not args.create_profile:
                raise OwnershipError(
                    "retained Codex profile missing; admission remains closed"
                )
            codex_native(
                candidate,
                "attach",
                "--host",
                "codex",
                "--scope",
                "user",
                "--home",
                candidate["profile"],
                "--release-sha256",
                candidate["externalReleaseSha256"],
                "--folder",
                args.folder,
                "--daily-folder",
                args.daily_folder,
            )
        for binding in retained:
            codex_drained(binding)
        record.update(
            owner="mcp" if args.operation == "codex-activate" else "disabled",
            phase="stable",
            delivery="plugin",
            generation=record["generation"] + 1,
        )
        write(path, record)
        return record


def codex_hook_input():
    payload = sys.stdin.buffer.read(262145)
    if len(payload) > 262144:
        raise OwnershipError("Codex hook payload exceeds bounded input")
    value = decode_json(payload)
    if not isinstance(value, dict):
        raise OwnershipError("Codex hook input must be a JSON object")
    return value


CODEX_EXEC_OPTIONS = {
    "execute-commit": ({"home", "session", "snapshot"}, set()),
    "prepare": ({"home", "session", "commit"}, set()),
    "request": ({"home", "session"}, set()),
    "status": ({"home", "session"}, set()),
    "retry": ({"home", "session", "payload-sha256", "verification"}, {"commit"}),
    "skip": ({"home", "session", "turn", "reason"}, set()),
    "takeover": ({"home", "session", "verification"}, set()),
    "resolve-snapshot": ({"home", "session", "snapshot", "verification"}, set()),
}


def codex_entrypoint():
    library = Path(__file__).resolve()
    package = (
        library.parents[4]
        if library.parents[2].name == "commit-capture"
        else library.parents[2] / "packages/codex"
    )
    return str(package / "scripts/capture.py")


def codex_authorization(home, record, current, cwd):
    value = dict(
        home=home,
        generation=record["generation"],
        global_generation=current["generation"],
        delivery=record["delivery"],
        binding={key: record[key] for key in CODEX_BINDING_KEYS},
        cwd=str(canonical_path(cwd, strict=True)),
    )
    return base64.urlsafe_b64encode(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).decode()


def codex_decode_authorization(token):
    if (
        not isinstance(token, str)
        or len(token) > 16384
        or not re.fullmatch(r"[A-Za-z0-9_-]+={0,2}", token)
    ):
        raise OwnershipError("invalid guarded command authorization")
    value = decode_json(base64.b64decode(token, altchars=b"-_", validate=True))
    if not isinstance(value, dict) or set(value) != {
        "home",
        "generation",
        "global_generation",
        "delivery",
        "binding",
        "cwd",
    }:
        raise OwnershipError("invalid guarded command authorization")
    for key in ("home", "cwd"):
        if (
            not isinstance(value[key], str)
            or not Path(value[key]).is_absolute()
            or str(canonical_path(value[key])) != value[key]
        ):
            raise OwnershipError("invalid guarded command path")
    if any(
        type(value[key]) is not int or value[key] < 0
        for key in ("generation", "global_generation")
    ) or value["delivery"] not in ("plugin", "managed"):
        raise OwnershipError("invalid guarded command generation or delivery")
    codex_binding(value["binding"])
    return value


def codex_guard_prefix(token):
    return [
        "/usr/bin/python3",
        "-I",
        "-B",
        codex_entrypoint(),
        "codex-execute",
        "--authorization",
        token,
        "--",
    ]


def codex_parse_executor(words):
    if (
        not words
        or words[0] not in CODEX_EXEC_OPTIONS
        or len(words) > 20
        or sum(len(word.encode()) for word in words) > 16384
        or len(words) % 2 != 1
    ):
        raise OwnershipError("unsupported guarded native command")
    operation = words[0]
    required, optional = CODEX_EXEC_OPTIONS[operation]
    options = {}
    for key, value in zip(words[1::2], words[2::2]):
        if (
            not key.startswith("--")
            or key[2:] not in required | optional
            or key[2:] in options
        ):
            raise OwnershipError("invalid or duplicate guarded native option")
        options[key[2:]] = value
    if not required <= set(options):
        raise OwnershipError("missing guarded native option")
    for key in ("session", "snapshot", "commit", "payload-sha256"):
        if key in options and not re.fullmatch(r"[0-9a-f]{64}", options[key]):
            raise OwnershipError("invalid guarded native identity")
    if "turn" in options and (
        not 1 <= len(options["turn"]) <= 200
        or any(ord(char) < 32 for char in options["turn"])
    ):
        raise OwnershipError("invalid guarded native turn")
    if "reason" in options and options["reason"] not in (
        "no_meaningful_work",
        "user_requested_no_capture",
    ):
        raise OwnershipError("invalid guarded native skip reason")
    if "verification" in options and options["verification"] != (
        "authoritative-path-inspected"
        if operation == "retry"
        else "command-stopped-and-history-inspected"
    ):
        raise OwnershipError("invalid guarded native verification")
    return operation, options


def codex_executor_home(binding, options, cwd):
    home = Path(options["home"])
    parent = Path(binding["profile"])
    if (
        not home.is_absolute()
        or str(canonical_path(home, strict=True)) != str(home)
        or home.parent != parent / "workspaces"
        or not re.fullmatch(r"[0-9a-f]{64}", home.name)
    ):
        raise OwnershipError("guarded native home is outside the selected profile")
    for path in (parent / "workspaces", home):
        if not existing_directory(path):
            raise OwnershipError("guarded native workspace unavailable")
    child = read(home / "capture-profile.json")
    if not isinstance(child, dict) or any(
        child.get(key) != value
        for key, value in dict(
            host="codex",
            profileMode="attached",
            parentHome=str(parent),
            bundle=binding["bundle"],
            releaseSha256=binding["externalReleaseSha256"],
            releaseId=binding["releaseId"],
            python=binding["python"],
            active=True,
        ).items()
    ):
        raise OwnershipError("guarded native workspace binding changed")
    project = child.get("project")
    if (
        not isinstance(project, str)
        or not Path(project).is_absolute()
        or not canonical_path(cwd, strict=True).is_relative_to(
            canonical_path(project, strict=True)
        )
    ):
        raise OwnershipError("guarded native workspace does not match the command")
    session = read(parent / "bindings" / (options["session"] + ".json"))
    if not isinstance(session, dict) or any(
        session.get(key) != value
        for key, value in dict(
            session=options["session"], workspace=home.name, project=project
        ).items()
    ):
        raise OwnershipError("guarded native session does not belong to this workspace")


def codex_guard_text(text, token, binding):
    decoder = json.JSONDecoder(object_pairs_hook=unique_fields)
    opaque = []
    cursor = 0
    while cursor < len(text):
        if text[cursor] in "{[":
            try:
                _, end = decoder.raw_decode(text, cursor)
            except ValueError:
                pass
            else:
                opaque.append((cursor, end))
                cursor = end
                continue
        cursor += 1
    replacements = []

    def protected(position):
        return any(start <= position < end for start, end in opaque)

    for start_marker, end_marker, operation in (
        ("acknowledge explicitly with ", " (or user_requested_no_capture)", "skip"),
        ("authorize an exact retry with ", ". Use the returned arguments", "retry"),
        ("Retrieve the frozen keeper save arguments with ", "; call ", "request"),
        (
            "Prepare the pending capture: pipe JSON ",
            ", then call ",
            "prepare",
        ),
        (
            "Prepare the pending commit before another commit: pipe JSON ",
            ", then call ",
            "prepare",
        ),
    ):
        position = 0
        while (position := text.find(start_marker, position)) >= 0:
            start = position + len(start_marker)
            if protected(position):
                position = start
                continue
            if operation == "prepare":
                separator = text.find(" to ", start)
                if separator < 0:
                    raise OwnershipError("unrecognized native preparation guidance")
                start = separator + 4
            end = text.find(end_marker, start)
            if end < 0:
                raise OwnershipError("unrecognized native recovery guidance")
            words = shlex.split(text[start:end])
            if words[:2] != [
                binding["python"],
                str(Path(binding["bundle"]) / "bin/obsidian-mcp-native"),
            ]:
                raise OwnershipError("unrecognized native guidance launcher")
            parsed, _ = codex_parse_executor(words[2:])
            if parsed != operation:
                raise OwnershipError("native guidance operation mismatch")
            replacements.append(
                (start, end, shlex.join([*codex_guard_prefix(token), *words[2:]]))
            )
            position = end + len(end_marker)
    for marker, operation, ending in (
        (
            "Inspect it with status --home ",
            "status",
            ", then rescue interrupted ownership with ",
        ),
        (
            "Clear it with takeover --home ",
            "takeover",
            " --verification command-stopped-and-history-inspected",
        ),
        (
            "then rescue interrupted ownership with takeover --home ",
            "takeover",
            " --verification command-stopped-and-history-inspected",
        ),
    ):
        position = 0
        while (position := text.find(marker, position)) >= 0:
            start = position + len(marker)
            if protected(position) or any(
                left <= position < right for left, right, _ in replacements
            ):
                position = start
                continue
            end = text.rfind(ending, start)
            while end >= 0 and protected(end):
                end = text.rfind(ending, start, end)
            if end < 0:
                raise OwnershipError("unrecognized native ownership guidance")
            home, separator, session = text[start:end].rpartition(" --session ")
            if not separator:
                raise OwnershipError(
                    "native ownership guidance is missing session identity"
                )
            words = [operation, "--home", home, "--session", session]
            command_start = start - len(operation + " --home ")
            if operation == "takeover":
                words.extend(
                    ("--verification", "command-stopped-and-history-inspected")
                )
                end += len(ending)
            codex_parse_executor(words)
            replacements.append(
                (command_start, end, shlex.join([*codex_guard_prefix(token), *words]))
            )
            position = end
    marker = "use resolve-snapshot with"
    position = 0
    while (position := text.find(marker, position)) >= 0:
        if not protected(position):
            replacements.append(
                (
                    position,
                    position + len(marker),
                    "use "
                    + shlex.join([*codex_guard_prefix(token), "resolve-snapshot"])
                    + " with",
                )
            )
        position += len(marker)
    native = str(Path(binding["bundle"]) / "bin/obsidian-mcp-native")
    position = 0
    while (position := text.find(native, position)) >= 0:
        if not protected(position) and not any(
            start <= position < end for start, end, _ in replacements
        ):
            raise OwnershipError(
                "unrecognized executable runtime guidance; pending evidence retained"
            )
        position += len(native)
    for start, end, replacement in sorted(replacements, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def codex_guard_output(output, token, binding):
    if not isinstance(output, dict):
        return output
    output = dict(output)
    for key in (
        "systemMessage",
        "reason",
        "stopReason",
        "note",
        "additionalContext",
        "permissionDecisionReason",
    ):
        if isinstance(output.get(key), str):
            output[key] = codex_guard_text(output[key], token, binding)
    if isinstance(output.get("hookSpecificOutput"), dict):
        output["hookSpecificOutput"] = codex_guard_output(
            output["hookSpecificOutput"], token, binding
        )
    if isinstance(output.get("wrapped"), str):
        words = shlex.split(output["wrapped"])
        if words[:2] != [
            binding["python"],
            str(Path(binding["bundle"]) / "bin/obsidian-mcp-native"),
        ]:
            raise OwnershipError("unrecognized snapshot executor")
        codex_parse_executor(words[2:])
        output["wrapped"] = shlex.join([*codex_guard_prefix(token), *words[2:]])
    for key in ("snapshots", "before"):
        if isinstance(output.get(key), dict):
            output[key] = (
                {
                    name: codex_guard_output(value, token, binding)
                    if isinstance(value, dict)
                    else value
                    for name, value in output[key].items()
                }
                if key == "snapshots"
                else codex_guard_output(output[key], token, binding)
            )
    if isinstance(output.get("snapshot_resolutions"), list):
        output["snapshot_resolutions"] = [
            codex_guard_output(value, token, binding)
            for value in output["snapshot_resolutions"]
        ]
    return output


def codex_unwrap_executor(value, home, record, current):
    if value.get("tool_name") != "Bash" or not isinstance(
        value.get("tool_input"), dict
    ):
        return value
    command = value["tool_input"].get("command")
    if not isinstance(command, str):
        return value
    try:
        words = shlex.split(command)
    except ValueError:
        return value
    prefix = codex_guard_prefix("")
    if words[:5] != prefix[:5]:
        return value
    if len(words) < 9 or words[:6] != prefix[:6] or words[7] != "--":
        raise OwnershipError("invalid packaged executor command")
    ticket = codex_decode_authorization(words[6])
    codex_check_authorization(ticket, home, record, current)
    operation, options = codex_parse_executor(words[8:])
    if operation != "execute-commit":
        return value
    codex_executor_home(ticket["binding"], options, ticket["cwd"])
    original = shlex.join(
        [
            record["python"],
            str(Path(record["bundle"]) / "bin/obsidian-mcp-native"),
            *words[8:],
        ]
    )
    return dict(value, tool_input=dict(value["tool_input"], command=original))


def codex_check_authorization(ticket, home, record, current):
    if (
        record is None
        or ticket["home"] != home
        or record["owner"] != "mcp"
        or record["phase"] != "stable"
        or ticket["generation"] != record["generation"]
        or ticket["global_generation"] != current["generation"]
        or ticket["delivery"] != record["delivery"]
        or ticket["binding"] != {key: record[key] for key in CODEX_BINDING_KEYS}
    ):
        raise OwnershipError(
            "stale or closed guarded command admission; pending evidence retained"
        )
    check_exclusion(current, ticket["cwd"])


class GuardInterrupted(OwnershipError):
    def __init__(self, signum):
        super().__init__("guarded execution interrupted; pending evidence retained")
        self.signum = signum


@contextlib.contextmanager
def codex_execution_signals():
    interrupted = [None]
    previous = {}

    def interrupt(signum, _frame):
        interrupted[0] = signum

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous[signum] = signal.signal(signum, interrupt)
    try:
        yield interrupted
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def codex_guard_write(stream, payload, deadline, interrupted):
    descriptor = stream.fileno()
    flags = fcntl.fcntl(descriptor, fcntl.F_GETFL)
    deadline = min(deadline, time.monotonic() + 5)
    remaining = memoryview(payload)
    try:
        fcntl.fcntl(descriptor, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        with selectors.SelectSelector() as selector:
            selector.register(descriptor, selectors.EVENT_WRITE)
            while remaining:
                if interrupted[0] is not None:
                    raise GuardInterrupted(interrupted[0])
                budget = deadline - time.monotonic()
                if budget <= 0:
                    raise OwnershipError(
                        "guarded output timed out; pending evidence retained"
                    )
                if not selector.select(min(0.1, budget)):
                    continue
                try:
                    written = os.write(descriptor, remaining[:8192])
                except BlockingIOError:
                    continue
                remaining = remaining[written:]
    finally:
        fcntl.fcntl(descriptor, fcntl.F_SETFL, flags)


def codex_guard_message(message, stream=None):
    try:
        with codex_execution_signals() as interrupted:
            codex_guard_write(
                stream if stream is not None else sys.stderr.buffer,
                message.encode(),
                time.monotonic() + 1,
                interrupted,
            )
    except (OwnershipError, OSError):
        pass


class CodexGuardParser(argparse.ArgumentParser):
    def _print_message(self, message, file=None):
        if message:
            codex_guard_message(message, file)


def codex_execute_stream(binding, words, descriptor, payload, deadline, interrupted):
    codex_verify(binding)
    command = [
        binding["python"],
        "-I",
        "-B",
        str(Path(binding["bundle"]) / "bin/obsidian-mcp-native"),
        *words,
    ]
    execute = words[0] == "execute-commit"
    output = bytearray()
    with (
        tempfile.TemporaryFile() as source,
        selectors.DefaultSelector() as selector,
    ):
        if payload is not None:
            source.write(payload)
            source.seek(0)
        if interrupted[0] is not None:
            raise GuardInterrupted(interrupted[0])
        process = subprocess.Popen(
            command,
            stdin=source if payload is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(
                os.environ,
                PYTHONDONTWRITEBYTECODE="1",
                OBSIDIAN_CAPTURE_LEASE_FD=str(descriptor),
            ),
            pass_fds=(descriptor,),
            start_new_session=True,
        )
        try:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            total = 0
            while selector.get_map():
                if interrupted[0] is not None:
                    raise GuardInterrupted(interrupted[0])
                if time.monotonic() >= deadline:
                    raise OwnershipError(
                        "guarded native command exceeded its execution budget; pending evidence retained"
                    )
                for key, _ in selector.select(
                    max(0, min(1, deadline - time.monotonic()))
                ):
                    chunk = os.read(key.fileobj.fileno(), 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    total += len(chunk)
                    if total > 1048576:
                        raise OwnershipError(
                            "guarded native output exceeds limit; pending evidence retained"
                        )
                    if key.data == "stdout" and not execute:
                        output.extend(chunk)
                    else:
                        stream = (
                            sys.stdout.buffer
                            if key.data == "stdout"
                            else sys.stderr.buffer
                        )
                        codex_guard_write(stream, chunk, deadline, interrupted)
            while process.poll() is None:
                if interrupted[0] is not None:
                    raise GuardInterrupted(interrupted[0])
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise OwnershipError(
                        "guarded native execution timed out; pending evidence retained"
                    )
                try:
                    process.wait(timeout=min(1, remaining))
                except subprocess.TimeoutExpired:
                    continue
            if interrupted[0] is not None:
                raise GuardInterrupted(interrupted[0])
            result = process.returncode
            return result if result >= 0 else 128 - result, bytes(output)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            process.stdout.close()
            process.stderr.close()


def codex_prepare_input():
    deadline = time.monotonic() + 5
    payload = bytearray()
    with selectors.SelectSelector() as selector:
        selector.register(sys.stdin.buffer, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise OwnershipError("guarded native input timed out")
            chunk = os.read(sys.stdin.fileno(), 262145 - len(payload))
            if not chunk:
                return bytes(payload)
            payload.extend(chunk)
            if len(payload) > 262144:
                raise OwnershipError("guarded native input exceeds limit")


def codex_execute_main(arguments):
    parser = CodexGuardParser(
        description="Execute an allowlisted capture operation under writer admission"
    )
    parser.add_argument("--authorization", required=True)
    parser.add_argument("native", nargs=argparse.REMAINDER)
    args = parser.parse_args(arguments)
    words = args.native[1:] if args.native[:1] == ["--"] else args.native
    try:
        ticket = codex_decode_authorization(args.authorization)
        operation, options = codex_parse_executor(words)
        payload = codex_prepare_input() if operation == "prepare" else None
        with codex_execution_signals() as interrupted, admission() as descriptor:
            home = codex_home(ticket["home"])
            record = codex_record(home)
            current = codex_require_global()
            codex_check_authorization(ticket, home, record, current)
            binding = ticket["binding"]
            codex_capabilities(binding)
            codex_profile(binding)
            codex_executor_home(binding, options, ticket["cwd"])
            deadline = time.monotonic() + (360 if operation == "execute-commit" else 30)
            result, output = codex_execute_stream(
                binding, words, descriptor, payload, deadline, interrupted
            )
            if output:
                if not result and operation not in (
                    "prepare",
                    "request",
                    "retry",
                    "skip",
                ):
                    value = decode_json(output)
                    output = (
                        json.dumps(
                            codex_guard_output(value, args.authorization, binding)
                        )
                        + "\n"
                    ).encode()
                codex_guard_write(sys.stdout.buffer, output, deadline, interrupted)
            return result
    except GuardInterrupted as error:
        codex_guard_message("capture executor: " + str(error) + "\n")
        return 128 + error.signum
    except (
        OwnershipError,
        OSError,
        ValueError,
        TypeError,
        KeyError,
        AttributeError,
        RecursionError,
        subprocess.SubprocessError,
    ) as error:
        codex_guard_message(
            "capture executor: "
            + (
                str(error)
                if isinstance(error, OwnershipError)
                else "guarded operation unavailable; pending evidence retained"
            )
            + "\n"
        )
        return 2


def codex_route(args, home, value):
    if value.get("hook_event_name", args.event) != args.event:
        raise OwnershipError("Codex hook event mismatch")
    initial = codex_record(home)
    if initial is None or initial["delivery"] != args.delivery:
        return {}
    with admission() as descriptor:
        home = codex_home(home)
        record = codex_record(home)
        if record["delivery"] != args.delivery:
            return {}
        current = codex_require_global()
        if record["owner"] != "mcp" or record["phase"] != "stable":
            raise OwnershipError(
                "Codex writer ownership is "
                + record["owner"]
                + "/"
                + record["phase"]
                + "; no legacy fallback"
            )
        check_exclusion(current, value.get("cwd"))
        binding = {key: record[key] for key in CODEX_BINDING_KEYS}
        deadline = time.monotonic() + 8
        codex_capabilities(binding, deadline)
        codex_profile(binding, deadline)
        token = codex_authorization(home, record, current, value.get("cwd"))
        value = codex_unwrap_executor(value, home, record, current)
        value["hook_event_name"] = args.event
        output = codex_native(
            binding,
            "hook",
            "--home",
            binding["profile"],
            payload=value,
            descriptor=descriptor,
            deadline=deadline,
        )
        if set(output) - {
            "hookSpecificOutput",
            "decision",
            "reason",
            "systemMessage",
            "continue",
            "stopReason",
            "suppressOutput",
        }:
            raise OwnershipError("invalid Codex hook output")
        specific = output.get("hookSpecificOutput")
        if specific is not None and (
            not isinstance(specific, dict)
            or specific.get("hookEventName") != args.event
        ):
            raise OwnershipError("invalid Codex hook output event")
        output = codex_guard_output(output, token, binding)
        specific = output.get("hookSpecificOutput", {})
        if isinstance(specific.get("updatedInput"), dict):
            command = specific["updatedInput"].get("command")
            if isinstance(command, str):
                words = shlex.split(command)
                if words[:2] != [
                    binding["python"],
                    str(Path(binding["bundle"]) / "bin/obsidian-mcp-native"),
                ]:
                    raise OwnershipError(
                        "unrecognized native executor command; pending evidence retained"
                    )
                codex_parse_executor(words[2:])
                specific["updatedInput"]["command"] = shlex.join(
                    [*codex_guard_prefix(token), *words[2:]]
                )
        return output


def codex_hook_failure(args, value, message):
    tool = value.get("tool_name") if isinstance(value, dict) else None
    unknown = not isinstance(tool, str) or not tool
    if args.event == "PreToolUse" and (
        tool in CODEX_WRITES
        or args.tool_class == "owned-write"
        or (unknown and args.tool_class != "ordinary")
    ):
        return dict(
            hookSpecificOutput=dict(
                hookEventName=args.event,
                permissionDecision="deny",
                permissionDecisionReason=message,
            )
        )
    return dict(systemMessage=message)


def codex_main():
    parser = argparse.ArgumentParser(
        description="Verified Codex capture activation; preview unless --apply"
    )
    parser.add_argument(
        "operation",
        choices=("codex-status", "codex-activate", "codex-disable", "codex-route"),
    )
    parser.add_argument("--codex-home")
    parser.add_argument("--bundle")
    parser.add_argument("--release-sha256")
    parser.add_argument("--profile")
    parser.add_argument("--delivery", choices=("plugin", "managed"), default="plugin")
    parser.add_argument("--event", choices=CODEX_EVENTS)
    parser.add_argument("--tool-class", choices=("owned-write", "ordinary"))
    parser.add_argument("--create-profile", action="store_true")
    parser.add_argument("--folder", default="Sessions")
    parser.add_argument("--daily-folder", default="Daily")
    parser.add_argument("--verification")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    value = None
    try:
        if args.operation == "codex-route":
            value = codex_hook_input()
            if args.event == "PreToolUse":
                tool = value.get("tool_name")
                if not isinstance(tool, str) or not tool:
                    raise OwnershipError("Codex tool identity unavailable")
                if (args.tool_class == "owned-write" and tool not in CODEX_WRITES) or (
                    args.tool_class == "ordinary" and tool in CODEX_WRITES
                ):
                    raise OwnershipError(
                        "Codex trusted handler class does not match tool identity"
                    )
        home = codex_home(args.codex_home)
        if args.operation == "codex-route":
            if args.event is None:
                raise OwnershipError("Codex hook event required")
            result = codex_route(args, home, value)
        elif args.operation == "codex-status":
            record = codex_record(home)
            result = dict(
                status="dormant" if record is None else "configured",
                codex_home=home,
                ownership=record,
                global_ownership=ownership(read_only=True),
            )
        else:
            result = codex_transition(args, home)
    except (
        OwnershipError,
        OSError,
        ValueError,
        TypeError,
        KeyError,
        AttributeError,
        RecursionError,
        subprocess.SubprocessError,
    ) as error:
        message = (
            str(error)
            if isinstance(error, OwnershipError)
            else "Codex capture verification failed; inspect retained private state, no fallback"
        )
        if args.operation != "codex-route":
            print("capture: " + message, file=sys.stderr)
            return 2
        result = codex_hook_failure(args, value, message)
    print(json.dumps(result, sort_keys=True))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "operation",
        choices=(
            "lease",
            "legacy",
            "route",
            "status",
            "inspect-legacy",
            "handoff",
            "resume",
            "record-commit",
            "resolve-legacy",
            "reflog",
        ),
    )
    parser.add_argument("--owner", choices=("legacy", "mcp", "disabled"))
    parser.add_argument("--host", choices=("codex",))
    parser.add_argument("--profile")
    parser.add_argument("--scope", choices=("project", "user"), default="project")
    parser.add_argument("--exclude-project", action="append", default=[])
    parser.add_argument("--clear-exclusions", action="store_true")
    parser.add_argument("--project")
    parser.add_argument("--verification")
    parser.add_argument("--event")
    parser.add_argument("--script")
    parser.add_argument("--commit")
    parser.add_argument("--vault")
    parser.add_argument("--target")
    parser.add_argument("--evidence")
    parser.add_argument("--evidence-sha256")
    parser.add_argument("--reason")
    args, command = parser.parse_known_args()
    if command[:1] == ["--"]:
        command = command[1:]
    if command and args.operation not in ("legacy", "route"):
        raise OwnershipError("unexpected arguments")
    if args.operation == "lease":
        return 0 if lease_valid() else 1
    if args.operation == "inspect-legacy":
        result = inspect_legacy()
        print(json.dumps(result, sort_keys=True))
        return 0 if result["ready"] else 1
    if args.operation == "record-commit":
        commit_record(args)
        return 0
    if args.operation == "reflog":
        if not args.project:
            raise OwnershipError("project required")
        print(reflog_digest(args.project) or "unavailable")
        return 0
    if args.operation == "legacy":
        if not command:
            raise OwnershipError("legacy command required")
        return legacy(command, host=args.host)
    if args.operation == "route":
        return route(args.event, args.script, command)
    if args.operation == "resume":
        result = resume()
    elif args.operation == "resolve-legacy":
        result = resolve_legacy(args)
    elif args.operation == "handoff":
        if not args.owner:
            raise OwnershipError("owner required")
        result = transition(args)
    else:
        with admission():
            result = ownership()
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (
        OwnershipError,
        OSError,
        ValueError,
        TypeError,
        KeyError,
        subprocess.SubprocessError,
    ) as error:
        message = (
            str(error)
            if isinstance(error, OwnershipError)
            else "cannot initialize capture state; check XDG_STATE_HOME or HOME and private file permissions"
        )
        print("capture-owner: " + message, file=sys.stderr)
        if sys.argv[1:2] == ["route"]:
            event = (
                sys.argv[sys.argv.index("--event") + 1]
                if "--event" in sys.argv
                else "Stop"
            )
            if event == "Stop":
                result = dict(systemMessage=message)
            elif event == "PreToolUse" and (
                not isinstance(HOOK_INPUT, dict)
                or HOOK_INPUT.get("tool_name") != "Bash"
            ):
                result = dict(
                    hookSpecificOutput=dict(
                        hookEventName=event,
                        permissionDecision="deny",
                        permissionDecisionReason=message,
                    )
                )
            else:
                result = dict(
                    hookSpecificOutput=dict(
                        hookEventName=event,
                        additionalContext="Obsidian capture unavailable; ordinary work may continue. "
                        + message,
                    )
                )
            print(json.dumps(result))
            sys.exit(0)
        sys.exit(2)
