"""Local activity checkpoints. No provider calls; persisted state contains hashes only."""
import hashlib
import json
import math
import os
import re
from pathlib import Path
import runpy
import subprocess
import time


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def git_activity(cwd, previous_head=None):
    def git(*args):
        result = subprocess.run(
            ["git", "--no-optional-locks", "-C", cwd, *args],
            capture_output=True, text=True, timeout=5,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
        if result.returncode:
            return None
        return result.stdout.strip()
    if not cwd:
        return {"available": False}, None
    try:
        head = git("rev-parse", "HEAD")
        status = git("status", "--porcelain=v1", "--untracked-files=normal")
        unstaged = git("diff", "--no-ext-diff", "--no-textconv", "--numstat")
        staged = git("diff", "--cached", "--no-ext-diff", "--no-textconv", "--numstat")
        if None in (head, status, unstaged, staged):
            return {"available": False}, None
        revision = (previous_head + "..HEAD" if isinstance(previous_head, str)
                    and re.fullmatch(r"[0-9a-f]{40,64}", previous_head) else "HEAD")
        commits = git("log", "-5", "--format=%h %s", revision, "--")
        evidence = {"available": True, "head": head, "recent_commits": (commits or "")[:2000],
                    "status": status[:3000], "unstaged_numstat": unstaged[:2000],
                    "staged_numstat": staged[:2000]}
        return evidence, sha(json.dumps([head, status, unstaged, staged]))
    except (OSError, subprocess.TimeoutExpired):
        return {"available": False}, None


def checkpoint(snapshot, config, state, cwd, forced):
    previous_path = state / "activity.json"
    previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
    if not isinstance(previous, dict):
        raise ValueError("invalid activity state")
    seen = previous.get("seen", [])
    last_attempt = previous.get("last_attempt", 0)
    if (not isinstance(seen, list) or any(not isinstance(v, str) for v in seen)
            or type(last_attempt) not in (int, float) or not math.isfinite(last_attempt)):
        raise ValueError("invalid activity state")
    scalar = runpy.run_path(str(Path(__file__).with_name("summary-call.py")))["scalar"]
    interval = int(scalar(str(config), "summary_interval_secs", "900"))
    minimum = int(scalar(str(config), "summary_min_messages", "3"))
    if interval < 0 or minimum < 1:
        raise ValueError("invalid activity thresholds")
    extract = runpy.run_path(str(Path(__file__).with_name("autosave-input.py")))["extract"]
    events = extract(snapshot)[0]
    fingerprints = [event["fp"] for event in events]
    known = set(seen)
    pending = [event for event in events if event["fp"] not in known]
    meaningful = [event for event in pending if event["kind"] in ("user", "assistant")
                  and len(event["text"].strip()) >= 80]
    git, git_hash = git_activity(cwd, previous.get("head"))
    git_changed = (git_hash is not None and git_hash != previous.get("git")
                   and (bool(git.get("status")) or bool(previous.get("git"))))
    now = time.time()
    facts = {"pending_messages": len(meaningful), "git_changed": git_changed,
             "interval_secs": interval, "minimum_messages": minimum}
    if not forced:
        if now - last_attempt < interval:
            return "deferred_interval", facts, None, None
        if not pending or (len(meaningful) < minimum and not (git_changed and meaningful)):
            return "deferred_activity", facts, None, None
    next_state = {"version": 1, "seen": [fp for fp in fingerprints if fp in known], "git": git_hash,
                  "head": git.get("head"), "last_attempt": now, "current": fingerprints}
    context = None if forced else {"seen": sorted(known), "git": git}
    return "eligible", facts, next_state, context
