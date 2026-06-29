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

# --- op: append ---

# append needs no title, but needs a date or target + body
cat > "$TMP/append-date.md" <<'EOF'
op: append
date: 2026-06-29
section: ## 14:30 — Topic
---
appended content
EOF
kspayload_validate "$TMP/append-date.md" || fail "append with date+body should pass"

cat > "$TMP/append-target.md" <<'EOF'
op: append
target: Daily/2026-06-29.md
---
appended content
EOF
kspayload_validate "$TMP/append-target.md" || fail "append with target+body should pass"

# append without date AND without target must fail
cat > "$TMP/append-notarget.md" <<'EOF'
op: append
---
appended content
EOF
kspayload_validate "$TMP/append-notarget.md" 2>/dev/null && fail "append without date/target must fail"

# append without body must fail
cat > "$TMP/append-nobody.md" <<'EOF'
op: append
date: 2026-06-29
---
EOF
kspayload_validate "$TMP/append-nobody.md" 2>/dev/null && fail "append without body must fail"

# unknown op must fail (no silent fallback to insert)
cat > "$TMP/badop.md" <<'EOF'
op: appned
date: 2026-06-29
---
content
EOF
kspayload_validate "$TMP/badop.md" 2>/dev/null && fail "unknown op must fail"

# explicit op: insert still requires title
cat > "$TMP/insert-notitle.md" <<'EOF'
op: insert
---
body here
EOF
kspayload_validate "$TMP/insert-notitle.md" 2>/dev/null && fail "explicit insert without title must fail"

echo "PASS: keeper-save-payload"
