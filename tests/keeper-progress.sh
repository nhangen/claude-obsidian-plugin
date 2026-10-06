#!/usr/bin/env bash
# keeper-progress.sh — #170: the keeper reports which insert steps landed, for
# the MCP adapter to name what a cut-off save left unfinished. The markers are
# opt-in (KEEPER_PROGRESS=1, set only by the adapter) so other --format json
# callers, such as session-summarize.sh, never see them.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPER="$ROOT_DIR/scripts/keeper"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-progress-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
V="$TMP/vault"; mkdir -p "$V/.obsidian" "$V/Inbox" "$V/Daily"

insert() {  # insert <title> [extra args...]; stderr -> $TMP/err
  local title="$1"; shift
  printf '%s body\n' "$title" | bash "$KEEPER" insert --vault "$V" --target "Inbox/$title.md" \
    --title "$title" --request-id "req-$RANDOM" "$@" >"$TMP/out" 2>"$TMP/err"
}

# Default: no markers, in either format — session-summarize.sh runs exactly
# this shape (--format json with --session-link-date) without the opt-in.
insert "Quiet" --session-link-date 2026-10-06 --daily-path Daily --format json
grep -q '"status":"committed"' "$TMP/out" || fail "quiet insert did not commit: $(cat "$TMP/out" "$TMP/err")"
! grep -q 'keeper-progress' "$TMP/err" || fail "markers leaked without KEEPER_PROGRESS: $(cat "$TMP/err")"
KEEPER_PROGRESS=1 insert "Text Mode"
! grep -q 'keeper-progress' "$TMP/err" || fail "markers leaked in text format: $(cat "$TMP/err")"

# Opted in: every step, in order, with the pending set named up front.
KEEPER_PROGRESS=1 insert "Linked" --session-link-date 2026-10-06 --daily-path Daily --format json
grep -q '"status":"committed"' "$TMP/out" || fail "linked insert did not commit: $(cat "$TMP/out" "$TMP/err")"
[ "$(grep '^keeper-progress: ' "$TMP/err")" = "keeper-progress: note-written pending=index,daily-link
keeper-progress: index-written
keeper-progress: daily-link-written" ] || fail "unexpected markers:"$'\n'"$(cat "$TMP/err")"

# Without a daily link, INDEX is the only pending step (the MCP keeper_save shape).
KEEPER_PROGRESS=1 insert "Index Only" --format json
[ "$(grep '^keeper-progress: ' "$TMP/err")" = "keeper-progress: note-written pending=index
keeper-progress: index-written" ] || fail "unexpected markers without a daily link:"$'\n'"$(cat "$TMP/err")"

# A backslash in a title reaches the daily Session Link verbatim: the link once
# went through `awk -v`, which expands escapes.
insert 'Back\tslash' --session-link-date 2026-10-06 --daily-path Daily --format json
grep -qxF -- '- [[Inbox/Back\tslash]]' "$V/Daily/2026-10-06.md" \
  || fail "backslash title mangled in Session Links:"$'\n'"$(cat "$V/Daily/2026-10-06.md")"

echo "PASS: keeper-progress"
