#!/usr/bin/env bash
# config-doctor.sh — SessionStart hook.
#
# Turns the silent "plugin installed but unconfigured" state into a visible
# advisory. When the plugin is not usefully configured on this host but a synced
# vault is detectable, emit a SessionStart additionalContext message so the
# agent surfaces it and can offer /obsidian:setup. Without usable config the
# Stop hook (autosave) and the vaultkeeper watcher silently no-op, so the
# missing config is otherwise invisible — that gap cost a long investigation on
# ML-1 (vault synced, plugin never set up there).
#
# Advisory only: a hook cannot prompt for input (additionalContext is injected
# context, not an interactive dialog — see ~/.claude/rules/claude-code-hook-output-semantics).
# It makes the state discoverable; the agent relays it and the human runs setup.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
. "${SCRIPT_DIR}/lib/resolve-config.sh"

# Opt-out, for a host that has a vault but is deliberately not wired to the
# plugin. Lives OUTSIDE obsidian.local.md (which by definition is absent on the
# advisory path), so an env var or a sentinel file in the config dir.
SILENCE_FILE="$(dirname "$(obsidian_config_stable_path)")/.doctor-silence"
[ -n "${OBSIDIAN_DOCTOR_SILENCE:-}" ] && exit 0
[ -f "$SILENCE_FILE" ] && exit 0

# A resolved file that is empty or has no vault_path is NOT usable config — the
# autosave + keeper hooks also no-op on it, so treating it as healthy would
# recreate the invisible misconfig this hook exists to surface.
STATE="missing"   # missing | incomplete | ok
CFG="$(resolve_obsidian_config "$PLUGIN_ROOT" 2>/dev/null || true)"
if [ -n "$CFG" ] && [ -f "$CFG" ]; then
  if grep -q '^vault_path:[[:space:]]*[^[:space:]]' "$CFG"; then
    STATE="ok"
  else
    STATE="incomplete"
  fi
fi
[ "$STATE" = "ok" ] && exit 0

# Only advise where there is plausibly something to configure: a synced vault
# present but unconfigured. The list is the known-locations allowlist; a vault
# at a custom path stays silent rather than triggering a $HOME-wide scan.
HINT=""
for d in "$HOME/Documents/Obsidian" "$HOME/Obsidian" "$HOME/sync/Obsidian" "$HOME/vault"; do
  if [ -d "$d" ]; then HINT="$d"; break; fi
done
[ -n "$HINT" ] || exit 0

HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo 'this host')"
STABLE="$(obsidian_config_stable_path)"

# Escape for a JSON string: backslash, quote, and the control chars that can
# legally appear in a path/hostname. JSON forbids raw control chars, so an
# unescaped newline/tab would make the whole object invalid and drop the advisory.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

if [ "$STATE" = "incomplete" ]; then
  WHAT="present but incomplete (no vault_path in ${CFG})"
else
  WHAT="missing (no obsidian.local.md at ${STABLE})"
fi
MSG="Obsidian plugin is installed on ${HOST} but its config is ${WHAT}. A synced vault appears to be at ${HINT}, while autosave, commit-capture, and the vaultkeeper watcher stay dormant until it is configured. Offer to run /obsidian:setup to enable them, or 'touch ${SILENCE_FILE}' to dismiss this notice."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
  "$(json_escape "$MSG")"
exit 0
