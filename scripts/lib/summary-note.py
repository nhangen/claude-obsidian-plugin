#!/usr/bin/env python3
"""Pin automatic checkpoints for one source/vault/day to a canonical log note via keeper."""
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import runpy
import subprocess
import sys
import tempfile
import time

_statefile = runpy.run_path(str(Path(__file__).with_name("statefile.py")))
write_record = _statefile["write_record"]
state_home = _statefile["state_home"]
STALE_POINTER_SECONDS = 30 * 24 * 3600
INVALID_INPUT_EXIT = 4


def prune_stale_pointers(directory, current):
    cutoff = time.time() - STALE_POINTER_SECONDS
    for pointer in directory.glob("*.json"):
        if pointer == current:
            continue
        try:
            if pointer.lstat().st_mtime < cutoff:
                pointer.unlink()
                Path(str(pointer) + ".lock").unlink(missing_ok=True)
        except OSError:
            continue


def without_reserved_keys(frontmatter):
    return "\n".join(line for line in frontmatter.split("\n")
                     if not re.match(r"(capture_scope|checkpoint_source_key):", line))


def checkpoint_body(text):
    lines = []
    fence = None
    for line in text.splitlines(keepends=True):
        delimiter = re.match(r"^ {0,3}(`{3,}|~{3,})(.*?)(?:\r?\n)?$", line)
        if delimiter:
            marker = delimiter[1]
            if fence is None and not (marker[0] == "`" and "`" in delimiter[2]):
                fence = marker
            elif (fence is not None and marker[0] == fence[0]
                  and len(marker) >= len(fence) and not delimiter[2].strip()):
                fence = None
        if fence is None and not delimiter:
            line = re.sub(r"^(#{1,5}) ", lambda m: "#" * max(3, len(m[1]) + 1) + " ", line)
        lines.append(line)
    if fence is not None:
        lines.append("\n" + fence + "\n")
    return "".join(lines)


def save(vault, source, proposed, body, title, date, daily, usage, input_file):
    if not vault:
        raise ValueError("missing vault")
    vault = Path(vault).resolve(strict=True)
    if not vault.is_dir():
        raise ValueError("invalid vault")
    key = hashlib.sha256((str(vault) + "\0" + str(Path(source).resolve())).encode()).hexdigest()
    directory = state_home() / "claude-obsidian/summary-notes"
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("invalid state directory")
    directory.chmod(0o700)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise ValueError("invalid date")
    record = directory / f"{key}-{date}.json"
    descriptor = os.open(str(record) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if record.is_symlink():
            raise ValueError("invalid state record")
        if record.exists():
            state = json.loads(record.read_text())
            if (not isinstance(state, dict) or state.get("version") != 1 or not isinstance(state.get("target"), str)
                    or type(state.get("ready")) is not bool):
                raise ValueError("invalid state record")
        else:
            target = PurePosixPath(proposed)
            state = {"version": 1, "target": str(target.with_name(f"{target.stem}-{key[:12]}.md")),
                     "ready": False}
        target = PurePosixPath(state["target"])
        if target.is_absolute() or ".." in target.parts or "\n" in str(target):
            raise ValueError("invalid target")
        receipt = json.loads(Path(usage).read_text())
        rows = [json.loads(line) for line in Path(input_file).read_text().splitlines()]
        if not rows or not isinstance(rows[0], dict) or rows[0].get("kind") != "extraction_metadata":
            raise ValueError("invalid checkpoint input")
        boundary = hashlib.sha256(json.dumps(rows[1:], sort_keys=True,
            separators=(",", ":")).encode()).hexdigest()
        timestamp = receipt["started_at"]
        if not isinstance(timestamp, str) or not re.fullmatch(r"[0-9T:.+Z-]+", timestamp):
            raise ValueError("invalid timestamp")
        content = Path(body).read_text()
        if not content.startswith("---\n") or "\n---\n" not in content[4:]:
            raise ValueError("missing frontmatter")
        frontmatter, _, text = content[4:].partition("\n---\n")
        frontmatter = without_reserved_keys(frontmatter)
        main, coverage_heading, coverage = text.rpartition("\n## Autosave Input Coverage\n")
        text = (checkpoint_body(main) + "\n### Autosave Input Coverage\n" + coverage
                if coverage_heading else checkpoint_body(text))
        section = f"## Checkpoint {timestamp} {boundary}"
        keeper = Path(__file__).resolve().parents[1] / "keeper"
        base = ["bash", str(keeper)]
        note = vault / str(target)
        if state["ready"] and not note.exists() and not note.is_symlink():
            state["ready"] = False
        write_record(record, state)
        prune_stale_pointers(directory, record)
        with tempfile.TemporaryDirectory(prefix="obsidian-checkpoint-") as scratch:
            staged = Path(scratch) / "body.md"
            if not state["ready"]:
                if note.exists():
                    # Re-inserting the existing note lets --recover finish INDEX and the daily link after a partial first save.
                    initial_body = note
                else:
                    staged.write_text(
                        f"---\n{frontmatter}\ncapture_scope: checkpoint_log\n"
                        f"checkpoint_source_key: {key}\n---\n\n# {title}\n\n"
                        "Chronological checkpoint log, oldest first. Each checkpoint records only its "
                        "observed input; full-session completeness is not established.\n\n"
                        f"{section}\n\n{text}")
                    initial_body = staged
                result = subprocess.run(base + ["insert", "--vault", str(vault), "--target", str(target),
                    "--body-file", str(initial_body), "--title", title,
                    "--session-link-date", date, "--daily-path", daily, "--recover", "--format", "json"],
                    check=False)
                if result.returncode:
                    return result.returncode
                state["ready"] = True
                write_record(record, state)
            if not note.is_file() or note.is_symlink():
                raise ValueError("missing canonical note")
            staged.write_text(text)
            return subprocess.run(base + ["append", "--vault", str(vault), "--target", str(target),
                "--section", section, "--body-file", str(staged), "--skip-if-hash", boundary,
                "--format", "json"], check=False).returncode


if __name__ == "__main__":
    try:
        sys.exit(save(*sys.argv[1:]))
    except (OSError, ValueError, TypeError, KeyError) as error:
        reason = str(error) if type(error) is ValueError else type(error).__name__
        print(f"summary-note: checkpoint write failed ({reason}); activity remains pending", file=sys.stderr)
        sys.exit(1 if isinstance(error, OSError) else INVALID_INPUT_EXIT)
