#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$ROOT_DIR/skills/save-conversation/SKILL.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
need() { grep -q -- "$1" "$F" || fail "missing: $1"; }
absent() { grep -q -- "$1" "$F" && fail "should be gone (inline dup): $1" || true; }

need 'allowlist-validate.sh'
need 'allowlist_validate'
need 'dedup-scan.sh'
need 'dedup_same_day'
need 'tokenize_slug'
# the inline Jaccard prose must be gone (now delegated to the lib)
absent 'compute .A ∩ B'
echo "PASS: sole-brain-save-conversation"
