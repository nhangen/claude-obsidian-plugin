#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
DOCTOR="${ROOT_DIR}/scripts/config-doctor.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cd-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Run the hook with a controlled HOME/XDG so config resolution is deterministic.
run_doctor() {
  HOME="$1" XDG_CONFIG_HOME="$1/.config" OBSIDIAN_LOCAL_MD="" bash "$DOCTOR"
}

# --- config present + usable -> silent ---
H1="$WORK/h1"; mkdir -p "$H1/.config/claude-obsidian" "$H1/Documents/Obsidian"
printf -- '---\nvault_path: %s\n---\n' "$H1/Documents/Obsidian" \
  > "$H1/.config/claude-obsidian/obsidian.local.md"
OUT="$(run_doctor "$H1")"
[ -z "$OUT" ] || fail "usable config must emit nothing, got: $OUT"

# --- config absent + a synced vault is detectable -> advisory (valid JSON) ---
H2="$WORK/h2"; mkdir -p "$H2/.config" "$H2/Documents/Obsidian"
OUT="$(run_doctor "$H2")"
[ -n "$OUT" ] || fail "config absent + vault present must advise"
python3 -c "
import json,sys
d=json.loads('''$OUT''')
o=d['hookSpecificOutput']
assert set(o.keys())=={'hookEventName','additionalContext'}, o   # exact shape, not just substring
assert o['hookEventName']=='SessionStart', o
ctx=o['additionalContext']
assert 'obsidian:setup' in ctx and 'Documents/Obsidian' in ctx, ctx
" || fail "advisory JSON malformed / wrong shape: $OUT"

# --- config present but INCOMPLETE (no vault_path) -> advisory ---
H4="$WORK/h4"; mkdir -p "$H4/.config/claude-obsidian" "$H4/Documents/Obsidian"
printf -- '---\nauto_save: true\n---\n' > "$H4/.config/claude-obsidian/obsidian.local.md"
OUT="$(run_doctor "$H4")"
[ -n "$OUT" ] || fail "incomplete config (no vault_path) must advise"
echo "$OUT" | python3 -c "import json,sys;c=json.load(sys.stdin)['hookSpecificOutput']['additionalContext'];assert 'incomplete' in c, c" \
  || fail "incomplete-config advisory should say 'incomplete': $OUT"

# --- control chars in the interpolated path -> still valid JSON (F1 regression) ---
HW="$WORK/we\"ird"$'\n'"path"; mkdir -p "$HW/.config" "$HW/Documents/Obsidian"
OUT="$(run_doctor "$HW")"
[ -n "$OUT" ] || fail "weird-path host should still advise"
printf '%s' "$OUT" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())   # fails if newline/quote/backslash left unescaped
assert 'obsidian:setup' in d['hookSpecificOutput']['additionalContext']
" || fail "control-char/quote path produced invalid JSON: $OUT"

# --- opt-out: env var silences ---
H5="$WORK/h5"; mkdir -p "$H5/.config" "$H5/Documents/Obsidian"
OUT="$(HOME="$H5" XDG_CONFIG_HOME="$H5/.config" OBSIDIAN_LOCAL_MD="" OBSIDIAN_DOCTOR_SILENCE=1 bash "$DOCTOR")"
[ -z "$OUT" ] || fail "OBSIDIAN_DOCTOR_SILENCE=1 must silence the advisory, got: $OUT"

# --- opt-out: sentinel file silences ---
H6="$WORK/h6"; mkdir -p "$H6/.config/claude-obsidian" "$H6/Documents/Obsidian"
touch "$H6/.config/claude-obsidian/.doctor-silence"
OUT="$(run_doctor "$H6")"
[ -z "$OUT" ] || fail "sentinel .doctor-silence must silence the advisory, got: $OUT"

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
