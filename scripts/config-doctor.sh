#!/usr/bin/env bash
# config-doctor.sh — SessionStart hook.
#
# Turns the silent "plugin installed but unconfigured" state into a visible
# advisory. When no obsidian.local.md resolves on this host but a synced vault
# is detectable, emit a SessionStart additionalContext message so the agent
# surfaces it and can offer /obsidian:setup. Without config the Stop hook
# (autosave) and the vaultkeeper watcher silently no-op, so the missing config
# is otherwise invisible — that gap is exactly what cost a long investigation
# on ML-1.
#
# Advisory only: a hook cannot prompt for input (additionalContext is injected
# context, not an interactive dialog — see ~/.claude/rules/claude-code-hook-output-semantics).
# It makes the state discoverable; the agent relays it and the human runs setup.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
. "${SCRIPT_DIR}/lib/resolve-config.sh"

# Config already present -> nothing to advise.
if resolve_obsidian_config "$PLUGIN_ROOT" >/dev/null 2>&1; then
  exit 0
fi

# Only advise where there is plausibly something to configure: a synced vault
# is present but unconfigured. Hosts with no vault aren't meant to run the
# plugin, so stay silent there rather than nag every session.
HINT=""
for d in "$HOME/Documents/Obsidian" "$HOME/Obsidian" "$HOME/sync/Obsidian" "$HOME/vault"; do
  if [ -d "$d" ]; then HINT="$d"; break; fi
done
[ -n "$HINT" ] || exit 0

HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo 'this host')"
STABLE="$(obsidian_config_stable_path)"

json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

MSG="Obsidian plugin is installed on ${HOST} but not configured (no obsidian.local.md at ${STABLE}). A synced vault appears to be at ${HINT}, but autosave, commit-capture, and the vaultkeeper watcher are all dormant until configured. Offer to run /obsidian:setup to enable them."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
  "$(json_escape "$MSG")"
exit 0
