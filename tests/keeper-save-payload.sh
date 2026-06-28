#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/keeper-save-payload.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ksp-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ok.md" <<'EOF'
title: Long-arc finding on X
folder_hint: CEO/agents/hari-seldon
type: finding
links: Note A, Note B
---
The body of the finding.
Second line.
EOF

[ "$(kspayload_field "$TMP/ok.md" title)" = "Long-arc finding on X" ] || fail "title parse"
[ "$(kspayload_field "$TMP/ok.md" folder_hint)" = "CEO/agents/hari-seldon" ] || fail "folder_hint parse"
[ "$(kspayload_field "$TMP/ok.md" type)" = "finding" ] || fail "type parse"
[ "$(kspayload_body "$TMP/ok.md" | head -1)" = "The body of the finding." ] || fail "body parse"
[ "$(kspayload_links "$TMP/ok.md")" = "$(printf -- '[[Note A]]\n[[Note B]]')" ] || fail "links normalize"
kspayload_validate "$TMP/ok.md" || fail "valid payload should pass"

# missing title
cat > "$TMP/notitle.md" <<'EOF'
type: note
---
body here
EOF
kspayload_validate "$TMP/notitle.md" 2>/dev/null && fail "missing title must fail"

# missing body (no --- / empty after marker)
cat > "$TMP/nobody.md" <<'EOF'
title: Has title only
---
EOF
kspayload_validate "$TMP/nobody.md" 2>/dev/null && fail "missing body must fail"

echo "PASS: keeper-save-payload"
