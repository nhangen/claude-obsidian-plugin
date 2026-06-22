#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
DOCTOR="${ROOT_DIR}/scripts/config-doctor.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cd-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Run the hook with a controlled HOME/XDG so config resolution is deterministic
# and not affected by the developer's real machine.
run_doctor() {
  HOME="$1" XDG_CONFIG_HOME="$1/.config" OBSIDIAN_LOCAL_MD="" bash "$DOCTOR"
}

# --- config present -> silent (nothing to advise) ---
H1="$WORK/h1"; mkdir -p "$H1/.config/claude-obsidian" "$H1/Documents/Obsidian"
printf -- '---\nvault_path: %s\n---\n' "$H1/Documents/Obsidian" \
  > "$H1/.config/claude-obsidian/obsidian.local.md"
OUT="$(run_doctor "$H1")"
[ -z "$OUT" ] || fail "config present must emit nothing, got: $OUT"

# --- config absent + a synced vault is detectable -> advisory ---
H2="$WORK/h2"; mkdir -p "$H2/.config" "$H2/Documents/Obsidian"
OUT="$(run_doctor "$H2")"
[ -n "$OUT" ] || fail "config absent + vault present must emit an advisory"
python3 -c "
import json,sys
d=json.loads('''$OUT''')
o=d['hookSpecificOutput']
assert o['hookEventName']=='SessionStart', o
ctx=o['additionalContext']
assert 'obsidian:setup' in ctx, ctx
assert 'Documents/Obsidian' in ctx, ctx
" || fail "advisory JSON malformed or missing setup/vault reference: $OUT"

# --- config absent + NO vault anywhere -> silent (don't nag unrelated hosts) ---
H3="$WORK/h3"; mkdir -p "$H3/.config"
OUT="$(run_doctor "$H3")"
[ -z "$OUT" ] || fail "no config + no vault must stay silent, got: $OUT"

# --- wiring: hooks.json registers the SessionStart hook ---
HJ="${ROOT_DIR}/hooks/hooks.json"
python3 -c "
import json
h=json.load(open('$HJ'))['hooks']
assert 'SessionStart' in h, 'no SessionStart hook registered'
cmds=[hk['command'] for grp in h['SessionStart'] for hk in grp['hooks']]
assert any('config-doctor.sh' in c for c in cmds), cmds
" || fail "hooks.json does not register config-doctor.sh on SessionStart"

echo "PASS: config-doctor"
