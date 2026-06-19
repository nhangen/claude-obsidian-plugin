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
sleep 1
ADDED2="$(vault_index_apply "$F" "$IDX")"
[ -z "$ADDED2" ] || fail "second apply should add nothing, got: $ADDED2"
PLAN="$(vault_index_plan "$F" "$IDX")"
[ -z "$PLAN" ] || fail "plan should be empty after apply, got: $PLAN"

# DROP: delete a note, apply -> state entry removed.
rm "$F/b.md"
vault_index_apply "$F" "$IDX" >/dev/null
[ -z "$(state_hash_for "$STATE" "b.md")" ] || fail "b.md should be dropped from state"

echo "PASS: vault-index-apply"
