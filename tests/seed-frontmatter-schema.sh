#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/seed-schema-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
VAULT="$TMP/vault"; mkdir -p "$VAULT"

mknote() { printf -- '---\n%s---\n\nbody\n' "$1" > "$VAULT/$2"; }
# 4 of 5 notes have tags+type (80%); date only in 1 (20%)
mknote $'tags: [x]\ntype: a\ndate: 1\n' n1.md
mknote $'tags: [x]\ntype: a\n'          n2.md
mknote $'tags: [x]\ntype: a\n'          n3.md
mknote $'tags: [x]\ntype: a\n'          n4.md
mknote $'title: x\n'                    n5.md

CFG="$TMP/obsidian.local.md"
printf -- '---\nvault_path: %s\n---\n' "$VAULT" > "$CFG"

OUT="$(bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG")"
grep -q '^frontmatter_required:' "$CFG" || fail "config not seeded"
SEEDED="$(grep '^frontmatter_required:' "$CFG" | sed 's/frontmatter_required: *//')"
grep -qw tags <<<"$SEEDED" || fail "tags (80%) should be required: $SEEDED"
grep -qw type <<<"$SEEDED" || fail "type (80%) should be required: $SEEDED"
grep -qw date <<<"$SEEDED" && fail "date (20%) must NOT be required: $SEEDED"

# Idempotent: a second run must not duplicate or overwrite the existing line.
bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG" >/dev/null
[ "$(grep -c '^frontmatter_required:' "$CFG")" -eq 1 ] || fail "duplicate frontmatter_required line"

# Explicit pre-existing value is preserved, not recomputed.
CFG2="$TMP/cfg2.md"
printf -- '---\nvault_path: %s\nfrontmatter_required: project\n---\n' "$VAULT" > "$CFG2"
bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG2" >/dev/null
[ "$(grep '^frontmatter_required:' "$CFG2" | sed 's/.*: *//')" = "project" ] || fail "existing value overwritten"

echo "PASS: seed-frontmatter-schema"
