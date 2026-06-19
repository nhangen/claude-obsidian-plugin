#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-apply-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
F="$TMP/Decisions"; mkdir -p "$F"
IDX="$F/INDEX.md"; printf '# Decisions Index\n' > "$IDX"
IDX_BEFORE="$(cat "$IDX")"
printf 'note A\n' > "$F/a.md"
printf 'note B\n' > "$F/b.md"
STATE="$(index_state_file "$IDX")"

# Cold start: no state -> both notes are ADD.
ADDED="$(vault_index_apply "$F" "$IDX")"
grep -qxF "a.md" <<<"$ADDED" || fail "expected a.md in ADD output"
grep -qxF "b.md" <<<"$ADDED" || fail "expected b.md in ADD output"
[ -f "$STATE" ] || fail "state file not created"
grep -q '^# last_reconciled:[0-9]\+$' "$STATE" || fail "no last_reconciled stamp"
note_hash_valid "$(state_hash_for "$STATE" "a.md")" || fail "a.md hash not stored validly"

# INDEX.md must be untouched by apply (append-only is the subagent's job).
[ "$(cat "$IDX")" = "$IDX_BEFORE" ] || fail "apply must not modify INDEX.md"

# Idempotent: second apply with no changes -> empty plan, no new ADD.
# Use explicit timestamps instead of sleep to avoid wall-clock dependency.
touch -t 202001010000 "$F/a.md" "$F/b.md"
ADDED2="$(vault_index_apply "$F" "$IDX")"
[ -z "$ADDED2" ] || fail "second apply should add nothing, got: $ADDED2"
PLAN="$(vault_index_plan "$F" "$IDX")"
[ -z "$PLAN" ] || fail "plan should be empty after apply, got: $PLAN"

# DROP: delete a note, apply -> state entry removed.
rm "$F/b.md"
vault_index_apply "$F" "$IDX" >/dev/null
[ -z "$(state_hash_for "$STATE" "b.md")" ] || fail "b.md should be dropped from state"

# Substring collision regression: b.md must survive when only b.md.md changes.
TMP2="$(mktemp -d "${TMPDIR:-/tmp}/vault-apply-substr-XXXXXX")"; trap 'rm -rf "$TMP2"' EXIT
F2="$TMP2/Decisions"; mkdir -p "$F2"
IDX2="$F2/INDEX.md"; printf '# Decisions Index\n' > "$IDX2"
printf 'content-b\n'      > "$F2/b.md"
printf 'content-bdouble\n' > "$F2/b.md.md"
STATE2="$(index_state_file "$IDX2")"

# First apply: seeds both entries.
vault_index_apply "$F2" "$IDX2" >/dev/null
note_hash_valid "$(state_hash_for "$STATE2" "b.md")"    || fail "setup: b.md hash missing"
note_hash_valid "$(state_hash_for "$STATE2" "b.md.md")" || fail "setup: b.md.md hash missing"

# Change only b.md.md, leave b.md at old timestamp.
touch -t 197001010000 "$F2/b.md"
printf 'content-bdouble-changed\n' > "$F2/b.md.md"

# Apply again: plan touches b.md.md (CHANGED), not b.md.
vault_index_apply "$F2" "$IDX2" >/dev/null

# b.md's state entry must still exist.
note_hash_valid "$(state_hash_for "$STATE2" "b.md")" \
  || fail "substring regression: b.md state entry was wrongly dropped when b.md.md changed"

# Unreadable file: chmod 000 -> apply must NOT create a malformed state entry.
TMP3="$(mktemp -d "${TMPDIR:-/tmp}/vault-apply-unreadable-XXXXXX")"; trap 'rm -rf "$TMP3"' EXIT
F3="$TMP3/Notes"; mkdir -p "$F3"
IDX3="$F3/INDEX.md"; printf '# Notes Index\n' > "$IDX3"
printf 'readable content\n' > "$F3/good.md"
printf 'secret content\n'   > "$F3/unreadable.md"
STATE3="$(index_state_file "$IDX3")"

# Make unreadable.md unreadable before the first apply.
chmod 000 "$F3/unreadable.md"
WARN="$(vault_index_apply "$F3" "$IDX3" 2>&1 >/dev/null)" || true
# Restore perms immediately so trap cleanup works.
chmod 644 "$F3/unreadable.md"

# good.md should be present with a valid hash; unreadable.md should be absent.
note_hash_valid "$(state_hash_for "$STATE3" "good.md")" \
  || fail "unreadable test: good.md hash should be valid"
STORED_UNREAD="$(state_hash_for "$STATE3" "unreadable.md")"
[ -z "$STORED_UNREAD" ] || note_hash_valid "$STORED_UNREAD" \
  || fail "unreadable file produced malformed state entry: $STORED_UNREAD"

echo "PASS: vault-index-apply"
