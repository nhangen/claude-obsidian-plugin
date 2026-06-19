#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="${ROOT_DIR}/agents/vault-librarian.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
need() { grep -qiF "$1" "$A" || fail "agent missing: $1"; }

[ -f "$A" ] || fail "agents/vault-librarian.md missing"
grep -q '^description:' "$A" || fail "missing frontmatter description"
need "resolve-config.sh"          # resolves vault dynamically
need "vault_index_apply"          # refreshes slice before answering
need "coverage"                   # coverage invariant present
need "find-notes"                 # raw-text fallback to find-notes skill
need "Pending.md"                 # low-confidence routing -> [ask]
need "dry-run"                    # destructive ops gated
need "strict_domains"             # respects allow-list
grep -q '## Hard Rules' "$A" || fail "missing Hard Rules section"
echo "PASS: vault-librarian-agent"
