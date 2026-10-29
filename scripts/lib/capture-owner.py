#!/usr/bin/env python3
"""Host-local writer admission and delegation to the public capture runtime."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
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


def read(path):
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


def legacy(command, payload=None):
    with admission() as descriptor:
        current = ownership()
        if current["phase"] != "stable" or current["owner"] != "legacy":
            raise OwnershipError(
                "local write refused: writer owner is "
                + current["owner"]
                + "/"
                + current["phase"]
                + "; use the configured MCP route, no local fallback"
            )
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
    if event == "UserPromptSubmit" and output.get("decision") == "block":
        output = dict(
            hookSpecificOutput=dict(
                hookEventName=event, additionalContext=output["reason"]
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
                **details
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


def capture_profile(current, cwd, deadline):
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
        if current["owner"] == "legacy":
            if fallback:
                return execute(["bash", fallback, *arguments], descriptor, payload)
            print("{}")
            return 0
        value = decode_json(payload)
        profile = capture_profile(current, value.get("cwd"), deadline)
        value["hook_event_name"] = event
        return public_hook(profile, descriptor, value, event, deadline)


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
        return legacy(command)
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
                result = (
                    dict(systemMessage=message)
                    if isinstance(HOOK_INPUT, dict)
                    and HOOK_INPUT.get("stop_hook_active")
                    else dict(decision="block", reason=message)
                )
            elif event == "PreToolUse" and HOOK_INPUT.get("tool_name") != "Bash":
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
            if event == "Stop" and isinstance(error, CaptureUnavailable):
                result = dict(systemMessage=message)
            print(json.dumps(result))
            sys.exit(0)
        sys.exit(2)
