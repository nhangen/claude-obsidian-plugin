#!/usr/bin/env bash
# session-save.sh
# Stop command hook. Reads transcript_path from the hook event JSON on stdin,
# copies the transcript, and spawns session-summarize.sh in the background.
# Exits immediately.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
. "${SCRIPT_DIR}/lib/resolve-config.sh"

CONFIG_FILE="$(resolve_obsidian_config "$PLUGIN_ROOT")" || CONFIG_FILE=""
if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  exit 0
fi

AUTO_SAVE=$(grep '^auto_save:' "$CONFIG_FILE" | head -1 | sed 's/^auto_save:[[:space:]]*//')
if [ "$AUTO_SAVE" = "false" ]; then
  exit 0
fi

VAULT_PATH=$(grep '^vault_path:' "$CONFIG_FILE" | head -1 | sed 's/^vault_path:[[:space:]]*//')
if [ -z "$VAULT_PATH" ] || [ ! -d "$VAULT_PATH" ]; then
  exit 0
fi

# Self-activate the vaultkeeper watcher on this host if it isn't scheduled yet.
# Cheap no-op once installed; never blocks autosave (opt out: keeper_autostart: false).
. "${SCRIPT_DIR}/lib/keeper-bootstrap.sh"
KEEPER_INTERVAL=$(grep '^keeper_interval_secs:' "$CONFIG_FILE" | head -1 | sed 's/^keeper_interval_secs:[[:space:]]*//')
keeper_ensure_active "$PLUGIN_ROOT" "$CONFIG_FILE" "$VAULT_PATH" "${KEEPER_INTERVAL:-900}" || true

if ! command -v python3 >/dev/null 2>&1; then
  echo "session-save.sh: python3 not found; autosave requires python3 to parse hook JSON" >&2
  exit 0
fi

# Command hooks receive a JSON payload on stdin, not the transcript itself.
# Extract transcript_path from the payload.
HOOK_JSON=$(cat)
TRANSCRIPT_PATH=$(printf '%s' "$HOOK_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('transcript_path', ''))
except Exception as e:
    print(f'session-save.sh: failed to parse hook JSON: {e}', file=sys.stderr)
" 2>/dev/null || true)

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

FILE_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
if [ -z "$FILE_SIZE" ] || [ "$FILE_SIZE" -lt 200 ]; then
  exit 0
fi

# Copy transcript to a temp file so session-summarize.sh can own and delete it
TMPFILE="$(mktemp "${TMPDIR:-/tmp}/obsidian-session-XXXXXX")" || exit 0
if ! cp "$TRANSCRIPT_PATH" "$TMPFILE"; then
  rm -f "$TMPFILE"
  exit 0
fi

nohup bash "${SCRIPT_DIR}/session-summarize.sh" "$TMPFILE" "$CONFIG_FILE" "$VAULT_PATH" &>/dev/null &

exit 0
