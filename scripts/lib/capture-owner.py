#!/usr/bin/env python3
"""Host-local writer admission and delegation to the public capture runtime."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

HOOK_INPUT = {}


class OwnershipError(ValueError):
    pass


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
        return json.load(stream)


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


def ownership():
    try:
        value = read(state_path() / "owner.json")
    except FileNotFoundError:
        return dict(schema=1, owner="legacy", phase="stable", generation=0, profiles={})
    if (
        not isinstance(value, dict)
        or value.get("schema") != 1
        or value.get("owner") not in ("legacy", "mcp", "disabled")
        or value.get("phase") not in ("stable", "draining")
        or type(value.get("generation")) is not int
        or not isinstance(value.get("profiles"), dict)
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
        result = execute(command, descriptor, payload)
        if result == 0 and len(command) > 2 and Path(command[1]).name == "keeper-core":
            acknowledge_commit(command[2:])
        return result


def commit_record(args):
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", args.commit or ""):
        raise OwnershipError("full commit hash required")
    target = Path(args.target)
    if target.is_absolute() or ".." in target.parts:
        raise OwnershipError("vault-relative commit target required")
    value = dict(
        hash=args.commit, vault=str(Path(args.vault).resolve()), target=str(target)
    )
    key = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
    with admission():
        current = ownership()
        if current["owner"] != "legacy" or current["phase"] != "stable":
            raise OwnershipError("legacy commit ownership changed")
        write(directory(state_path() / "pending-commits") / (key + ".json"), value)


def acknowledge_commit(arguments):
    def option(name):
        return arguments[arguments.index(name) + 1] if name in arguments else None

    if arguments[:1] != ["append"] or not option("--skip-if-hash"):
        return
    pending = state_path() / "pending-commits"
    if not pending.exists():
        return
    for path in pending.glob("*.json"):
        value = read(path)
        if (
            value["hash"] != option("--skip-if-hash")
            or value["target"] != option("--target")
            or value["vault"] != str(Path(option("--vault")).resolve())
        ):
            continue
        note = Path(value["vault"]) / value["target"]
        if not re.search(
            r"^## [^\n]*(?<![0-9a-fA-F])"
            + re.escape(value["hash"])
            + r"(?![0-9a-fA-F])[^\n]*$",
            note.read_text(),
            re.MULTILINE,
        ):
            raise OwnershipError("keeper succeeded but commit heading readback failed")
        archive = directory(state_path() / "acknowledged-commits")
        os.replace(path, archive / path.name)


def public_command(profile, operation):
    home = Path(profile)
    if not home.is_absolute() or home != home.resolve():
        raise OwnershipError("profile must be an absolute canonical path")
    config = read(home / "capture-profile.json")
    if config.get("host") != "claude-plugin" or config.get("active") is not True:
        raise OwnershipError("active public claude-plugin profile required")
    bundle = Path(config.get("bundle", ""))
    executable = bundle / "bin/obsidian-mcp-native"
    if not bundle.is_absolute() or not executable.is_file():
        raise OwnershipError("public capture runtime unavailable; no fallback")
    return [sys.executable, str(executable), operation, "--home", str(home)]


def public_drained(profile):
    result = subprocess.run(
        public_command(profile, "drain-status"),
        capture_output=True,
        check=False,
        timeout=30,
    )
    if result.returncode or json.loads(result.stdout).get("quiescent") is not True:
        raise OwnershipError(
            "public capture has pending or unverified work; admission remains closed"
        )


def public_hook(profile, descriptor, value, event):
    env = dict(os.environ, OBSIDIAN_CAPTURE_LEASE_FD=str(descriptor))
    try:
        result = subprocess.run(
            public_command(profile, "hook"),
            input=json.dumps(value).encode(),
            capture_output=True,
            env=env,
            pass_fds=(descriptor,),
            timeout=8,
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
        output = json.loads(result.stdout)
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
    print(json.dumps(output))
    return 0


def resolved(path):
    key = hashlib.sha256(str(path.relative_to(root())).encode()).hexdigest()
    try:
        record = read(state_path() / "resolutions" / (key + ".json"))
    except FileNotFoundError:
        return False
    return record.get("sha256") == evidence_digest(path)


def evidence_digest(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_size > 1048576
        ):
            raise OwnershipError("unsafe legacy evidence file")
        data = stream.read(1048577)
        if len(data) > 1048576:
            raise OwnershipError("legacy evidence exceeds bounded inspection")
        return hashlib.sha256(data).hexdigest()


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
        or root().resolve() not in path.resolve().parents
    ):
        raise OwnershipError("unsafe evidence path")
    with admission(exclusive=True):
        key = hashlib.sha256(str(relative).encode()).hexdigest()
        record = dict(
            evidence=str(relative),
            sha256=evidence_digest(path),
            verification=args.verification,
            reason=args.reason,
            status="operator_resolved_not_mcp_receipt",
        )
        write(directory(state_path() / "resolutions") / (key + ".json"), record)
        return record


def legacy_drained():
    base = root()
    for folder in (
        "pre-commit-head",
        "pre-commit-processing",
        "capture-ownership/pending-commits",
    ):
        path = base / folder
        if path.exists() and any(not resolved(item) for item in path.iterdir()):
            raise OwnershipError("unresolved legacy commit evidence in " + folder)
    captures = base / "session-capture"
    if not captures.exists():
        return
    for path in captures.glob("*/activity.lock"):
        descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise OwnershipError(
                    "legacy background worker is still active"
                ) from error
        finally:
            os.close(descriptor)
    for path in captures.glob("*/boundaries/*.json"):
        value = read(path)
        if not resolved(path) and (
            value.get("status") != "process_succeeded"
            or value.get("retry_required") is not False
        ):
            raise OwnershipError(
                "unresolved legacy session receipt; inspect retained session evidence"
            )
    for path in captures.glob("*/activity.json"):
        value = read(path)
        if not resolved(path) and (
            not isinstance(value.get("pending"), list) or value["pending"]
        ):
            raise OwnershipError(
                "unsent or historical unverified legacy activity remains"
            )
    for path in captures.glob("*/launches/*.json"):
        if not resolved(path) and read(path).get("status") != "observed":
            raise OwnershipError(
                "unobserved legacy capture launch remains; inspect or retry the original source"
            )


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
        for profile in profiles.values():
            public_drained(profile)
        if args.owner == "mcp":
            if not args.project or not args.profile:
                raise OwnershipError(
                    "MCP handoff requires project and attached public profile"
                )
            project = str(Path(args.project).resolve(strict=True))
            config = read(Path(args.profile) / "capture-profile.json")
            if config.get("project") != project:
                raise OwnershipError("profile project does not match handoff project")
            public_drained(args.profile)
            profiles[project] = args.profile
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


def route(event, fallback, arguments):
    global HOOK_INPUT
    payload = sys.stdin.buffer.read(262145)
    if len(payload) > 262144:
        raise OwnershipError("hook payload exceeds bounded input")
    try:
        HOOK_INPUT = json.loads(payload)
    except ValueError:
        HOOK_INPUT = {}
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
        value = json.loads(payload)
        cwd = value.get("cwd")
        if not isinstance(cwd, str) or not cwd or not Path(cwd).is_absolute():
            raise OwnershipError("hook project identity unavailable")
        found = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
        if found.returncode:
            raise OwnershipError("hook project is not a Git checkout")
        project = str(Path(found.stdout.strip()).resolve(strict=True))
        profile = current["profiles"].get(project)
        if not profile:
            raise OwnershipError(
                "no MCP capture profile for this project; no legacy fallback"
            )
        value["hook_event_name"] = event
        return public_hook(profile, descriptor, value, event)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "operation",
        choices=(
            "lease",
            "legacy",
            "route",
            "status",
            "handoff",
            "resume",
            "record-commit",
            "resolve-legacy",
            "reflog",
        ),
    )
    parser.add_argument("--owner", choices=("legacy", "mcp", "disabled"))
    parser.add_argument("--profile")
    parser.add_argument("--project")
    parser.add_argument("--verification")
    parser.add_argument("--event")
    parser.add_argument("--script")
    parser.add_argument("--commit")
    parser.add_argument("--vault")
    parser.add_argument("--target")
    parser.add_argument("--evidence")
    parser.add_argument("--reason")
    args, command = parser.parse_known_args()
    if command[:1] == ["--"]:
        command = command[1:]
    if command and args.operation not in ("legacy", "route"):
        raise OwnershipError("unexpected arguments")
    if args.operation == "lease":
        return 0 if lease_valid() else 1
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
            elif event == "UserPromptSubmit":
                result = dict(decision="block", reason=message)
            elif event == "PreToolUse":
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
                        hookEventName=event, additionalContext=message
                    )
                )
            print(json.dumps(result))
            sys.exit(0)
        sys.exit(2)
