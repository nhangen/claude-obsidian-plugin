#!/usr/bin/env bash
# session-save.sh
# Stop command hook. Reads transcript_path from the hook event JSON on stdin,
# copies the transcript, and spawns session-summarize.sh in the background.
# Exits immediately.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PLUGIN_ROOT}/obsidian.local.md"

if [ ! -f "$CONFIG_FILE" ]; then
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

# Command hooks receive a JSON payload on stdin, not the transcript itself.
# Extract transcript_path from the payload.
HOOK_JSON=$(cat)
TRANSCRIPT_PATH=$(printf '%s' "$HOOK_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('transcript_path', ''))
except Exception:
    pass
" 2>/dev/null || true)

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

FILE_SIZE=$(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ')
if [ "$FILE_SIZE" -lt 200 ]; then
  exit 0
fi

# Copy transcript to a temp file so session-summarize.sh can own and delete it
TMPFILE="$(mktemp "${TMPDIR:-/tmp}/obsidian-session-XXXXXX")"
cp "$TRANSCRIPT_PATH" "$TMPFILE"

nohup bash "${SCRIPT_DIR}/session-summarize.sh" "$TMPFILE" "$CONFIG_FILE" "$VAULT_PATH" &>/dev/null &

exit 0
