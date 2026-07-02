#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/allowlist-validate.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/allow-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

CFG="$TMP/cfg.md"
cat > "$CFG" <<'EOF'
## Project Taxonomy

| Domain | Vault path | Precedence | Notes |
|--------|-----------|------------|-------|
| Development | Projects/Development/ | 10 | code |
| Daily | Daily/ | 50 | dated |
| Inbox | Inbox/ | 99 | fallback |

## Routing Rules
EOF

# allowlist_list emits exactly the three rows, slash-stripped, header/separator excluded
got="$(allowlist_list "$CFG" | tr '\n' ',')"
[ "$got" = "Projects/Development,Daily,Inbox," ] || fail "allowlist_list got: [$got]"

# valid: exact root, dated subfolder, per-repo namespacing, case-insensitive
allowlist_validate "Daily/2026-06-29.md" "$CFG" || fail "dated subfolder should pass"
allowlist_validate "Projects/Development/nhangen/foo/x.md" "$CFG" || fail "namespaced path should pass"
allowlist_validate "projects/development/x.md" "$CFG" || fail "case-insensitive should pass"

# invalid: unknown top-level refused, non-zero, closest match surfaced
if allowlist_validate "Projcts/Development/x.md" "$CFG" 2>"$TMP/err"; then fail "typo top-level should be refused"; fi
grep -q 'Projects/Development' "$TMP/err" || fail "closest match not surfaced: $(cat "$TMP/err")"

# a folder that only shares a prefix substring but not a path segment is refused
if allowlist_validate "Dailyish/x.md" "$CFG" 2>/dev/null; then fail "Dailyish must not match Daily"; fi

if command -v zsh >/dev/null 2>&1; then
  zsh -c ". '$ROOT_DIR/scripts/lib/allowlist-validate.sh'; allowlist_list '$CFG'" >/dev/null 2>"$TMP/zerr" || { cat "$TMP/zerr" >&2; fail "allowlist-validate broke under zsh"; }
fi
echo "PASS: allowlist-validate"
