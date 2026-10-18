#!/usr/bin/env python3
import fcntl
import hashlib
import json
import os
import runpy
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

checkpoint = runpy.run_path(str(Path(__file__).with_name("activity_gate.py")))["checkpoint"]


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def write_record(path, record):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(record, stream, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def boundary(snapshot):
    messages = {}
    with snapshot.open(encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("invalid transcript record")
            if record.get("type") not in ("user", "assistant"):
                continue
            message = record.get("message")
            if not isinstance(message, dict) or not message.get("content"):
                continue
            message_id = record.get("uuid")
            identity = ((record["type"], message_id) if isinstance(message_id, str) and message_id
                        else ("position", len(messages)))
            messages[identity] = (record["type"], message_id, message["content"])
    if not messages:
        return None
    return digest(json.dumps(list(messages.values()), sort_keys=True, separators=(",", ":")))


def acknowledged(next_state, sent_path):
    try:
        sent = json.loads(sent_path.read_text(encoding="utf-8"))["sent"]
        if not isinstance(sent, list) or any(not isinstance(v, str) for v in sent):
            raise ValueError("invalid sent receipt")
    except (OSError, ValueError, KeyError, TypeError):
        sent = []
    delivered = set(sent) | set(next_state["seen"])
    state = {key: value for key, value in next_state.items() if key != "current"}
    state["seen"] = [fp for fp in next_state["current"]
                     if fp in delivered]
    return state


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir():
        raise ValueError("invalid state directory")
    path.chmod(0o700)


def prepare_state(vault, source, session_id):
    state_home = os.environ.get("XDG_STATE_HOME")
    if not state_home:
        home = os.environ.get("HOME")
        if not home:
            raise ValueError("HOME is required")
        state_home = str(Path(home) / ".local/state")
    source_id = digest(str(vault.resolve()) + "\0" +
                       (session_id or str(source.resolve())))
    state_root = Path(state_home) / "claude-obsidian/session-capture"
    private_directory(state_root)
    state = state_root / source_id
    private_directory(state)
    records = state / "boundaries"
    private_directory(records)
    for directory in (state, records):
        with tempfile.TemporaryFile(dir=directory):
            pass
    return source_id, state, records


def capture(snapshot, config, vault, source, session_id, retry, forced=False, cwd=""):
    _, state, _ = prepare_state(vault, source, session_id)
    descriptor = os.open(state / "activity.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        return capture_locked(snapshot, config, vault, source, session_id, retry, forced, cwd, lock.fileno())


def capture_locked(snapshot, config, vault, source, session_id, retry, forced, cwd, activity_fd):
    source_id, state, records = prepare_state(vault, source, session_id)
    event = {"source_session_hash": source_id, "time": time.time(),
             "provider_success": None, "usage": None}
    try:
        boundary_id = boundary(snapshot)
    except (ValueError, UnicodeError):
        write_record(state / "last-event.json", dict(event, status="invalid_transcript"))
        return 1
    if boundary_id is None:
        write_record(state / "last-event.json", dict(event, status="empty_boundary"))
        return 0
    event["boundary"] = boundary_id
    receipt_path = records / f"{boundary_id}.json"
    lock_path = records / f"{boundary_id}.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            write_record(state / "last-event.json", dict(event, status="deduplicated_in_flight"))
            return 0
        previous = {}
        if receipt_path.exists():
            try:
                with receipt_path.open(encoding="utf-8") as stream:
                    previous = json.load(stream)
                if (not isinstance(previous, dict) or
                        previous.get("status") not in ("running", "interrupted", "process_failed",
                                                       "process_succeeded") or
                        type(previous.get("attempt")) is not int or previous["attempt"] < 1):
                    raise ValueError("invalid capture receipt")
            except (ValueError, UnicodeError):
                write_record(state / "last-event.json", dict(event, status="invalid_receipt"))
                return 1
            if previous.get("status") == "running":
                previous.update(status="interrupted", retry_required=True)
                write_record(receipt_path, previous)
            if not retry or previous.get("status") == "process_succeeded":
                write_record(state / "last-event.json", dict(event, status="deduplicated",
                             previous_status=previous.get("status")))
                return 0
        try:
            status, facts, next_state, context = checkpoint(snapshot, config, state, cwd, forced or retry)
        except (OSError, ValueError, TypeError):
            write_record(state / "last-event.json", dict(event, status="activity_error"))
            raise
        if status != "eligible":
            write_record(state / "last-event.json", dict(event, status=status, activity=facts))
            return 0
        activity_path = state / "activity.json"
        previous_activity = json.loads(activity_path.read_text()) if activity_path.exists() else {}
        write_record(activity_path, dict(previous_activity, last_attempt=next_state["last_attempt"]))
        sent_path = state / f"sent-{boundary_id}.json"
        context_path = state / f"context-{boundary_id}.json"
        sent_path.unlink(missing_ok=True)
        child_env = dict(os.environ, AUTOSAVE_SENT_FILE=str(sent_path))
        child_env.pop("AUTOSAVE_CONTEXT_FILE", None)
        if context is not None:
            write_record(context_path, context)
            child_env["AUTOSAVE_CONTEXT_FILE"] = str(context_path)
        receipt = dict(event, schema_version=1, invocation_id=str(uuid.uuid4()), status="running",
                       worker_pid=os.getpid(), attempt=previous.get("attempt", 0) + 1,
                       snapshot_bytes=snapshot.stat().st_size, dedup_result="claimed",
                       retry_required=False, stage="summarizer_process")
        write_record(receipt_path, receipt)
        try:
            # The child retains ownership if this supervisor is killed mid-call.
            result = subprocess.run(
                ["bash", str(Path(__file__).resolve().parents[1] / "session-summarize.sh"),
                 str(snapshot), str(config), str(vault), str(source)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                pass_fds=(lock.fileno(), activity_fd), env=child_env, check=False)
            exit_code = result.returncode
        except OSError:
            exit_code = 127
        if exit_code == 0:
            write_record(activity_path, acknowledged(next_state, sent_path))
        context_path.unlink(missing_ok=True)
        sent_path.unlink(missing_ok=True)
        receipt.update(status="process_succeeded" if exit_code == 0 else "process_failed",
                       exit_code=exit_code, finished_at=time.time(),
                       retry_required=exit_code != 0)
        write_record(receipt_path, receipt)
        write_record(state / "last-event.json", receipt)
        return 0 if exit_code == 0 else 1


def main():
    os.umask(0o077)
    if sys.argv[1:2] == ["--prepare"]:
        try:
            vault, source, session_id = sys.argv[2:]
            prepare_state(Path(vault), Path(source), session_id)
            return 0
        except (OSError, ValueError, TypeError):
            print("session-capture: cannot initialize capture state; check XDG_STATE_HOME "
                  "or HOME/.local/state and directory permissions", file=sys.stderr)
            return 1
    snapshot, config, vault, source, session_id, retry = sys.argv[1:7]
    forced, cwd = (sys.argv[7:] or ["false", ""])
    try:
        if retry not in ("true", "false") or forced not in ("true", "false"):
            raise ValueError("invalid retry mode")
        return capture(Path(snapshot), Path(config), Path(vault), Path(source),
                       session_id, retry == "true", forced == "true", cwd)
    except (OSError, ValueError, TypeError):
        print("session-capture: capture failed; inspect private capture state before retrying",
              file=sys.stderr)
        return 1
    finally:
        Path(snapshot).unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
