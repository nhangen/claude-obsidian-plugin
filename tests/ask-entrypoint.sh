#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${ROOT_DIR}/skills/ask/SKILL.md"; C="${ROOT_DIR}/commands/ask.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$S" ] || fail "skills/ask/SKILL.md missing"
[ -f "$C" ] || fail "commands/ask.md missing"
grep -q '^name: ask$' "$S" || fail "skill name must be bare 'ask'"
grep -q '^description:' "$S" || fail "skill missing description"
grep -qiF "vault-librarian" "$S" || fail "skill must dispatch vault-librarian"
grep -qF '${CLAUDE_PLUGIN_ROOT}/skills/ask/SKILL.md' "$C" || fail "command must read the physical ownership-aware skill"
grep -q '^name: obsidian:ask$' "$C" || fail "commands/ask.md missing name: obsidian:ask"
echo "PASS: ask-entrypoint"
