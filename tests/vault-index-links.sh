#!/usr/bin/env bash
# vault-index-links.sh — issue #30: state must never claim coverage INDEX.md lacks.
# apply writes the links itself; plan treats "hashed but unlinked" as an ADD.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-links-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# --- apply writes the link, not just the hash ---
F="$TMP/Decisions"; mkdir -p "$F"
IDX="$F/INDEX.md"; printf '# Decisions Index\n' > "$IDX"
printf 'note A\n' > "$F/a.md"
printf 'note B\n' > "$F/b.md"
STATE="$(index_state_file "$IDX")"

vault_index_apply "$F" "$IDX" >/dev/null
grep -qxF -- '- [[a]]' "$IDX" || fail "apply did not write link for a.md"$'\n'"$(cat "$IDX")"
grep -qxF -- '- [[b]]' "$IDX" || fail "apply did not write link for b.md"
# Append-only: the pre-existing header survives, at the top.
[ "$(head -1 "$IDX")" = '# Decisions Index' ] || fail "apply rewrote INDEX.md instead of appending"

# --- idempotent: a second apply adds no duplicate link ---
touch -t 202001010000 "$F/a.md" "$F/b.md"
vault_index_apply "$F" "$IDX" >/dev/null
[ "$(grep -cxF -- '- [[a]]' "$IDX")" = 1 ] || fail "duplicate link appended for a.md"

# --- self-heal: state ahead of INDEX (the issue-30 drift) must reappear as ADD ---
# Simulate the damaged vault: drop a.md's link from INDEX while its hash stays in state.
grep -vxF -- '- [[a]]' "$IDX" > "$IDX.tmp" && mv "$IDX.tmp" "$IDX"
grep -qxF -- '- [[a]]' "$IDX" && fail "setup: a.md link should be gone"
note_hash_valid "$(state_hash_for "$STATE" "a.md")" || fail "setup: a.md hash should still be in state"

PLAN="$(vault_index_plan "$F" "$IDX")"
grep -qxF "ADD"$'\t'"a.md" <<<"$PLAN" \
  || fail "hashed-but-unlinked note must plan as ADD, got:"$'\n'"$PLAN"

ADDED="$(vault_index_apply "$F" "$IDX")"
grep -qxF "a.md" <<<"$ADDED" || fail "drifted note must be reported in the ADD set"
grep -qxF -- '- [[a]]' "$IDX" || fail "apply did not re-add the missing link"

# --- a hand-written link is respected: no ADD, no duplicate ---
F2="$TMP/Hand"; mkdir -p "$F2"
IDX2="$F2/INDEX.md"; printf '# Hand Index\n- [[h]]\n' > "$IDX2"
printf 'hand note\n' > "$F2/h.md"
vault_index_apply "$F2" "$IDX2" >/dev/null
[ "$(grep -cxF -- '- [[h]]' "$IDX2")" = 1 ] || fail "apply duplicated a hand-written link"

# Link variants (alias / heading) count as linked.
F3="$TMP/Variants"; mkdir -p "$F3"
IDX3="$F3/INDEX.md"; printf '# V Index\n- [[v1|Alias]]\n- [[v2#Section]]\n' > "$IDX3"
printf 'v1\n' > "$F3/v1.md"; printf 'v2\n' > "$F3/v2.md"
vault_index_apply "$F3" "$IDX3" >/dev/null
[ "$(grep -c -- '\[\[v1' "$IDX3")" = 1 ] || fail "aliased link not recognized as coverage"
[ "$(grep -c -- '\[\[v2' "$IDX3")" = 1 ] || fail "heading link not recognized as coverage"

# --- titles with regex metacharacters must match literally ---
F4="$TMP/Meta"; mkdir -p "$F4"
IDX4="$F4/INDEX.md"; printf '# Meta Index\n' > "$IDX4"
printf 'meta\n' > "$F4/2026-07-27 notes (draft) [v1+2].md"
vault_index_apply "$F4" "$IDX4" >/dev/null
grep -qxF -- '- [[2026-07-27 notes (draft) [v1+2]]]' "$IDX4" \
  || fail "metachar title not linked literally:"$'\n'"$(cat "$IDX4")"
touch -t 202001010000 "$F4/2026-07-27 notes (draft) [v1+2].md"
vault_index_apply "$F4" "$IDX4" >/dev/null
[ "$(grep -c -- '\[\[2026-07-27' "$IDX4")" = 1 ] || fail "metachar title link duplicated"

# --- missing INDEX.md is created, not silently skipped ---
F5="$TMP/Fresh"; mkdir -p "$F5"
IDX5="$F5/INDEX.md"
printf 'fresh\n' > "$F5/f.md"
vault_index_apply "$F5" "$IDX5" >/dev/null
[ -f "$IDX5" ] || fail "apply did not create a missing INDEX.md"
grep -qxF -- '- [[f]]' "$IDX5" || fail "apply did not link into the created INDEX.md"

# --- coverage check: state tracking more notes than INDEX links is a defect ---
# Callable on its own so a damaged vault can be assessed without a write.
vault_index_coverage_check "$F" "$IDX" 2>/dev/null || fail "healthy slice reported as a defect"
grep -vxF -- '- [[b]]' "$IDX" > "$IDX.tmp" && mv "$IDX.tmp" "$IDX"
if WARN="$(vault_index_coverage_check "$F" "$IDX" 2>&1 >/dev/null)"; then
  fail "coverage check passed while INDEX had fewer links than state tracks"
fi
case "$WARN" in *coverage*) : ;; *) fail "coverage defect not reported on stderr: $WARN" ;; esac

# apply runs the check itself, so the defect cannot be skipped by a caller that
# forgets to ask — and it heals the gap it just reported.
vault_index_apply "$F" "$IDX" >/dev/null
vault_index_coverage_check "$F" "$IDX" 2>/dev/null || fail "apply left a coverage defect behind"

# --- empty folder: neither state nor INDEX exists yet; must not abort set -e ---
F6="$TMP/Empty"; mkdir -p "$F6"
vault_index_apply "$F6" "$F6/INDEX.md" >/dev/null
vault_index_coverage_check "$F6" "$F6/INDEX.md" 2>/dev/null \
  || fail "coverage check failed on an empty folder"

echo "PASS: vault-index-links"
