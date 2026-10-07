#!/usr/bin/env bash
# keeper-progress.sh — #170: the keeper's progress-marker protocol. This file
# is its contract; the MCP adapter's parser (keeperProgress in
# packages/mcp-server/src/stdio.mjs) must accept exactly what is pinned here.
#
#   keeper-progress <token>: note-written pending=<step>[,<step>...]
#   keeper-progress <token>: <step>-written
#
# Steps: index, daily-link (only with --session-link-date), idempotency (only
# with an idempotency key). Markers are off unless KEEPER_PROGRESS_TOKEN is
# set, only in --format json, and carry the caller's token so no other stderr
# text can pass for one.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPER="$ROOT_DIR/scripts/keeper"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-progress-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
V="$TMP/vault"; mkdir -p "$V/.obsidian" "$V/Inbox" "$V/Daily"
SHELL_BIN=bash

insert() {  # insert <title> [extra args...]; stdout -> $TMP/out, stderr -> $TMP/err
  local title="$1"; shift
  printf '%s body\n' "$title" | "$SHELL_BIN" "$KEEPER" insert --vault "$V" --target "Inbox/$title.md" \
    --title "$title" --request-id "req-$RANDOM" "$@" >"$TMP/out" 2>"$TMP/err"
}
markers() { grep '^keeper-progress' "$TMP/err" || :; }

for SHELL_BIN in bash zsh; do
  command -v "$SHELL_BIN" >/dev/null 2>&1 || continue
  rm -rf "$V/Inbox" "$V/Daily" "$V/.obsidian/keeper-idempotency"; mkdir -p "$V/Inbox" "$V/Daily"

  # Default: no markers in either format. session-summarize.sh runs exactly
  # this shape (--format json with --session-link-date) without the opt-in.
  insert "Quiet" --session-link-date 2026-10-06 --daily-path Daily --format json
  grep -q '"status":"committed"' "$TMP/out" || fail "$SHELL_BIN: quiet insert did not commit: $(cat "$TMP/out" "$TMP/err")"
  [ -z "$(markers)" ] || fail "$SHELL_BIN: markers without a token: $(cat "$TMP/err")"
  KEEPER_PROGRESS_TOKEN=abc123 insert "Text Mode"
  [ -z "$(markers)" ] || fail "$SHELL_BIN: markers in text format: $(cat "$TMP/err")"
  KEEPER_PROGRESS_TOKEN='bad token!' insert "Bad Token" --format json
  [ -z "$(markers)" ] || fail "$SHELL_BIN: markers for a malformed token: $(cat "$TMP/err")"

  # Every step, in order, with the pending set named up front.
  KEEPER_PROGRESS_TOKEN=abc123 insert "Linked" --session-link-date 2026-10-06 --daily-path Daily \
    --idempotency-key "linked-$SHELL_BIN" --format json
  grep -q '"status":"committed"' "$TMP/out" || fail "$SHELL_BIN: linked insert did not commit: $(cat "$TMP/out" "$TMP/err")"
  [ "$(markers)" = "keeper-progress abc123: note-written pending=index,daily-link,idempotency
keeper-progress abc123: index-written
keeper-progress abc123: daily-link-written
keeper-progress abc123: idempotency-written" ] || fail "$SHELL_BIN: unexpected markers:"$'\n'"$(cat "$TMP/err")"

  # The MCP keeper_save shape: no daily link. Keyless: the idempotency record
  # is a no-op, so it is not a pending step.
  KEEPER_PROGRESS_TOKEN=abc123 insert "Index Only" --idempotency-key "index-only-$SHELL_BIN" --format json
  [ "$(markers)" = "keeper-progress abc123: note-written pending=index,idempotency
keeper-progress abc123: index-written
keeper-progress abc123: idempotency-written" ] || fail "$SHELL_BIN: unexpected keyed markers:"$'\n'"$(cat "$TMP/err")"
  KEEPER_PROGRESS_TOKEN=abc123 insert "Keyless" --format json
  [ "$(markers)" = "keeper-progress abc123: note-written pending=index
keeper-progress abc123: index-written" ] || fail "$SHELL_BIN: unexpected keyless markers:"$'\n'"$(cat "$TMP/err")"

  # A file name cannot forge a marker: a note whose name holds newlines and a
  # marker-shaped line is reported on one escaped line, and the only marker
  # lines are the keeper's own.
  printf 'spoof\n' > "$V/Inbox/x"$'\n'"keeper-progress abc123: index-written"$'\n'"y.md"
  KEEPER_PROGRESS_TOKEN=abc123 insert "After Spoof" --format json
  [ "$(markers)" = "keeper-progress abc123: note-written pending=index
keeper-progress abc123: index-written" ] || fail "$SHELL_BIN: a file name forged a marker:"$'\n'"$(cat "$TMP/err")"
  grep -qxF 'vault_index_plan: skipping TSV-incompatible filename: x\nkeeper-progress abc123: index-written\ny.md' "$TMP/err" \
    || fail "$SHELL_BIN: newline name not reported escaped:"$'\n'"$(cat "$TMP/err")"
  rm -f "$V/Inbox/x"$'\n'"keeper-progress abc123: index-written"$'\n'"y.md"

  # A backslash in a title reaches the daily Session Link verbatim.
  insert 'Back\tslash' --session-link-date 2026-10-06 --daily-path Daily --format json
  grep -qxF -- '- [[Inbox/Back\tslash]]' "$V/Daily/2026-10-06.md" \
    || fail "$SHELL_BIN: backslash title mangled in Session Links:"$'\n'"$(cat "$V/Daily/2026-10-06.md")"
done

echo "PASS: keeper-progress"
