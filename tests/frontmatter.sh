#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/frontmatter.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/frontmatter-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# complete note: tags + type present
cat > "$TMP/complete.md" <<'EOF'
---
date: 2026-06-20
tags: [a, b]
type: note
EOF
printf -- '---\n\nbody\n' >> "$TMP/complete.md"

# gap note: missing type
cat > "$TMP/gap.md" <<'EOF'
---
date: 2026-06-20
tags: [a]
EOF
printf -- '---\n\nbody\n' >> "$TMP/gap.md"

# no frontmatter at all
printf '# just a heading\n\nbody\n' > "$TMP/none.md"

KEYS="$(frontmatter_keys "$TMP/complete.md")"
grep -qxF tags <<<"$KEYS" || fail "complete: tags key not detected"
grep -qxF type <<<"$KEYS" || fail "complete: type key not detected"
grep -qxF date <<<"$KEYS" || fail "complete: date key not detected"
# list items must NOT be treated as keys
grep -qxF a <<<"$KEYS" && fail "list item leaked as key"

[ -z "$(frontmatter_missing "$TMP/complete.md" "tags type")" ] || fail "complete should have no missing keys"
[ "$(frontmatter_missing "$TMP/gap.md" "tags type")" = "type" ] || fail "gap should report missing type"
# no-frontmatter note is missing every required key
[ "$(frontmatter_missing "$TMP/none.md" "tags type" | sort | paste -sd, -)" = "tags,type" ] || fail "none should miss tags,type"

echo "PASS: frontmatter"
