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

# Fast Path section: presence, guards, gate ordering, config sourcing
need '## Fast Path'
need 'A topic hint was provided'
need 'Cross-Domain Tiebreaker'
need '#bookmark'
need 'Inbox/'
need 'No taxonomy domain matched'
need 'kspayload_validate <payload-file>'
need 'ask-staleness.sh'
# vault_path and the dedup threshold must be sourced from $CONFIG, not bare vars
grep -q "vault_path.*CONFIG\|CONFIG.*vault_path" "$F" || fail "missing: vault_path from \$CONFIG"
grep -qE 'dedup_jaccard_threshold:[[:space:]]*\$|dedup_jaccard_threshold.*"\$CONFIG"|\$\{dedup_jaccard_threshold:-0\.4\}' "$F" || true
grep -q -- '--vault "$VAULT"' "$F" || fail "missing: keeper insert --vault"
# fail-closed ordering inside the Fast Path: allowlist_validate must precede
# both kspayload_validate and the keeper insert call
FP="$(awk '/^## Fast Path/{f=1} f && /^## Config/{exit} f' "$F")"
echo "$FP" | grep -q allowlist_validate || fail "fast path missing allowlist_validate"
echo "$FP" | grep -q 'kspayload_validate' || fail "fast path missing kspayload_validate"
echo "$FP" | grep -q 'scripts/keeper" insert' || fail "fast path missing keeper insert"
[ "$(echo "$FP" | grep -n allowlist_validate | head -1 | cut -d: -f1)" -lt \
  "$(echo "$FP" | grep -n 'scripts/keeper" insert' | head -1 | cut -d: -f1)" ] \
  || fail "gate ordering: allowlist_validate must precede keeper insert"
[ "$(echo "$FP" | grep -n 'kspayload_validate' | head -1 | cut -d: -f1)" -lt \
  "$(echo "$FP" | grep -n 'scripts/keeper" insert' | head -1 | cut -d: -f1)" ] \
  || fail "gate ordering: kspayload_validate must precede keeper insert"
echo "PASS: sole-brain-save-conversation"
