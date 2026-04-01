#!/usr/bin/env bash
# session-save.sh
# Stop command hook. Saves the conversation transcript to a temp file
# and spawns session-summarize.sh in the background. Exits immediately.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PLUGIN_ROOT}/obsidian.local.md"

if [ ! -f "$CONFIG_FILE" ]; then
  exit 0
fi

VAULT_PATH=$(grep '^vault_path:' "$CONFIG_FILE" | head -1 | sed 's/^vault_path:[[:space:]]*//')
if [ -z "$VAULT_PATH" ] || [ ! -d "$VAULT_PATH" ]; then
  exit 0
fi

TMPFILE="$(mktemp "${TMPDIR:-/tmp}/obsidian-session-XXXXXX.json")"

cat > "$TMPFILE"

FILE_SIZE=$(wc -c < "$TMPFILE" | tr -d ' ')
if [ "$FILE_SIZE" -lt 200 ]; then
  rm -f "$TMPFILE"
  exit 0
fi

nohup bash "${SCRIPT_DIR}/session-summarize.sh" "$TMPFILE" "$CONFIG_FILE" "$VAULT_PATH" &>/dev/null &

exit 0
