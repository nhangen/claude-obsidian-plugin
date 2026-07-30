#!/usr/bin/env bash
# commit-capture-pre.sh
# PreToolUse command hook. Records HEAD for any Bash call that is about to invoke
# `git commit`, so the PostToolUse hook can require that HEAD actually moved
# instead of inferring a commit from the command text and the age of the tip.
#
# Why the snapshot exists: nothing in a PostToolUse payload links HEAD to the
# invocation being observed. A `git commit` that failed leaves the previous
# commit at the tip, and if that commit's capture was ever dropped, the failed
# call captures its predecessor and stamps it with the hook's clock rather than
# the commit's. `false && git commit` reproduced it end to end. HEAD_before vs
# HEAD_after observes the thing we actually care about.
#
# This hook must never fail the tool call it precedes: a PreToolUse hook exiting
# 2 blocks the Bash call, and any other non-zero surfaces an error to the user.
# Every step is best-effort and the script exits 0 unconditionally, silently, on
# both stdout and stderr.

set -uo pipefail

INPUT=$(cat)

case "$INPUT" in
  *'"command"'*commit*) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 0
LIB="${SCRIPT_DIR}/lib/commit-capture-parse.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=lib/commit-capture-parse.sh
. "$LIB" || exit 0

COMMAND_LINE="$(cc_json_value "$INPUT" '"command"')"
PAYLOAD_CWD="$(cc_json_value "$INPUT" '"cwd"')"

cc_invokes_commit "$COMMAND_LINE" || exit 0

# The repo the command names may not exist yet — `git worktree add ../wt && cd ../wt
# && git commit` and `mkdir sub && cd sub && git init && git commit` are both real
# shapes, and the first is this project's own documented workflow. Record the named
# directory regardless of whether it resolves *now*: without it, resolution fell
# through to the surrounding repo, the post-hook resolved the new one, the two roots
# disagreed, and the real commit was discarded as belonging to another repository.
INTENT=""
for cand in "$CC_GIT_C_DIR" "$CC_CD_TARGET"; do
  [ -n "$cand" ] || continue
  INTENT="$cand"
  break
done
# Absolutise it so the post-hook does not have to reproduce this hook's cwd, and so
# a relative `cd` cannot resolve against the wrong directory later.
case "$INTENT" in
  '') ;;
  '~') INTENT="$HOME" ;;
  '~/'*) INTENT="$HOME/${INTENT#\~/}" ;;
  /*) ;;
  *) [ -n "$PAYLOAD_CWD" ] && INTENT="$PAYLOAD_CWD/$INTENT" ;;
esac

SHA="unresolved"
ROOT=""
REPO_DIR="$(cc_find_repo_dir "$PAYLOAD_CWD")" || REPO_DIR=""
if [ -n "$REPO_DIR" ]; then
  ROOT=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null) || ROOT="$REPO_DIR"
  # An unborn HEAD is not a failure: the next commit is the repo's first, and
  # `none` still differs from whatever sha that produces.
  SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null) || SHA="none"
  case "$SHA" in
    *[!0-9a-f]*|'') SHA="none" ;;
  esac
elif [ -z "$INTENT" ]; then
  # Nothing resolved and the command named nothing, so there is no repository this
  # snapshot could be *about*. Writing one anyway produced a sha that matches no
  # HEAD and a root that matches every repo — a wildcard the post-hook could only
  # resolve with the same recent-tip guess the gate exists to replace.
  exit 0
fi

SNAP_DIR="$(cc_state_dir)/pre-commit-head"
mkdir -p "$SNAP_DIR" 2>/dev/null || exit 0

# A snapshot is consumed by the post-hook, which deletes it. One is left behind
# whenever the tool call never completes (denied, interrupted, session killed),
# so sweep anything older than a day. Only runs on commit-shaped calls, so this
# is not a per-Bash-call cost.
find "$SNAP_DIR" -type f -mtime +1 -delete 2>/dev/null || true

KEY="$(cc_snapshot_key "$INPUT")"
# One `key=value` per line, and every value is newline-free: sha passes a hex check,
# root comes from rev-parse, and a newline cannot survive the payload decode into a
# single shell token. The post-hook reads the keys it knows and ignores the rest, so
# adding a field does not strand an in-flight snapshot from an older version.
{ printf 'sha=%s\nroot=%s\nintent=%s\n' "$SHA" "$ROOT" "$INTENT" > "${SNAP_DIR}/${KEY}"; } 2>/dev/null || true

exit 0
