#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$ROOT_DIR/skills/create-note/SKILL.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
grep -q -- 'allowlist-validate.sh' "$F" || fail "missing lib source"
grep -q -- 'allowlist_validate' "$F" || fail "missing lib call"
grep -q -- 'Levenshtein' "$F" && fail "inline allow-list algorithm should be gone"
echo "PASS: sole-brain-create-note"
