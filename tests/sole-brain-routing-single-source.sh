#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMPL="$ROOT_DIR/obsidian.local.md.example"
[ -f "$TMPL" ] || fail "config template obsidian.local.md.example missing"
grep -q '## Routing Rules' "$TMPL" || fail "template has no ## Routing Rules"
# canonical routing block references the taxonomy table via allowlist_list, not hardcoded folders
grep -q 'allowlist_list' "$TMPL" || fail "canonical routing prose must point at allowlist_list"
# consumers reference the canonical source rather than re-describing candidate collection
for f in skills/save-conversation/SKILL.md skills/create-note/SKILL.md agents/vault-librarian.md; do
  grep -qi 'Routing Rules' "$ROOT_DIR/$f" || fail "$f does not reference the canonical Routing Rules"
done
echo "PASS: sole-brain-routing-single-source"
