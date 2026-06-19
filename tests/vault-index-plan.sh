#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
plan_has() { grep -qxF "$1" <<<"$2" || fail "expected plan line: $1"$'\n'"got:"$'\n'"$2"; }
plan_lacks() { grep -qxF "$1" <<<"$2" && fail "did not expect plan line: $1"; return 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-index-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
F="$TMP/Decisions"; mkdir -p "$F"
IDX="$F/INDEX.md"; printf -- '- [[a]]\n- [[b]]\n' > "$IDX"
printf 'note A body\n' > "$F/a.md"
printf 'note B body\n' > "$F/b.md"
printf 'brand new note\n' > "$F/c.md"

STATE="$(index_state_file "$IDX")"
[ "$STATE" = "$F/.INDEX.state" ] || fail "wrong sidecar path: $STATE"

# Seed state: a and b indexed with correct hashes, last_reconciled in the past.
{
  echo "# last_reconciled:1000"
  printf 'a.md\t%s\n' "$(note_hash "$F/a.md")"
  printf 'b.md\t%s\n' "$(note_hash "$F/b.md")"
} > "$STATE"

# Make a.md and b.md look OLD (mtime <= last_reconciled), c.md is new and unindexed.
touch -t 197001010000 "$F/a.md" "$F/b.md"

PLAN="$(vault_index_plan "$F" "$IDX")"
plan_has  "ADD"$'\t'"c.md" "$PLAN"          # coverage gap, no content read needed
plan_lacks "CHANGED"$'\t'"a.md" "$PLAN"     # old mtime + matching hash -> trusted
plan_lacks "CHANGED"$'\t'"b.md" "$PLAN"

# Syncthing mtime-bump: touch a.md NEWER than last_reconciled but DON'T change content.
touch "$F/a.md"
PLAN="$(vault_index_plan "$F" "$IDX")"
plan_lacks "CHANGED"$'\t'"a.md" "$PLAN"     # mtime newer but hash matches -> NOT changed

# Body-edit-only: change b.md content (and thus mtime).
printf 'note B body EDITED\n' > "$F/b.md"
PLAN="$(vault_index_plan "$F" "$IDX")"
plan_has  "CHANGED"$'\t'"b.md" "$PLAN"      # mtime newer AND hash differs -> changed

# Dangling: state references a deleted file.
printf 'gone.md\tjunk\n' >> "$STATE"
PLAN="$(vault_index_plan "$F" "$IDX")"
plan_has "DROP"$'\t'"gone.md" "$PLAN"

# Malformed stored hash -> forced reconcile (cold path), not silent skip.
{
  echo "# last_reconciled:1000"
  printf 'a.md\tNOTAHASH\n'
} > "$STATE"
touch -t 197001010000 "$F/a.md"            # old mtime; malformed hash must still trigger
PLAN="$(vault_index_plan "$F" "$IDX")"
plan_has "CHANGED"$'\t'"a.md" "$PLAN"

echo "PASS: vault-index-plan"
