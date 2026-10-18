#!/usr/bin/env bash
# session-save.sh
# Stop command hook. Reads transcript_path from the hook event JSON on stdin,
# copies the transcript, and starts the shared capture worker in the background.
# Exits immediately.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
. "${SCRIPT_DIR}/lib/resolve-config.sh"

# Recursion guard: session-summarize.sh runs `claude --print` with OBSIDIAN_SUMMARIZING=1,
# and that nested session must not autosave itself.
[ -n "${OBSIDIAN_SUMMARIZING:-}" ] && exit 0

: "${HOME:?HOME must be set for session capture}"
CAPTURE_REQUESTED=false
RETRY_REQUESTED=false
case "${1:-}" in
  '') ;;
  --capture) CAPTURE_REQUESTED=true ;;
  --retry) CAPTURE_REQUESTED=true; RETRY_REQUESTED=true ;;
  *) printf 'session-save: expected --capture or --retry\n' >&2; exit 1 ;;
esac

CONFIG_FILE="$(resolve_obsidian_config "$PLUGIN_ROOT")" || CONFIG_FILE=""
if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  exit 0
fi

AUTO_SAVE=$(OBSIDIAN_LOCAL_MD="$CONFIG_FILE" obsidian_config_value auto_save || true)
if [ "$AUTO_SAVE" = "false" ] && [ "$CAPTURE_REQUESTED" = false ]; then
  exit 0
fi

if SUMMARY_CAPTURE=$(OBSIDIAN_LOCAL_MD="$CONFIG_FILE" obsidian_config_value summary_capture); then
  case "$SUMMARY_CAPTURE" in
    stop|explicit) ;;
    *) printf 'session-save: summary_capture must be stop or explicit\n' >&2; exit 0 ;;
  esac
else
  SUMMARY_CAPTURE=stop
fi
case "$SUMMARY_CAPTURE" in
  explicit) [ "$CAPTURE_REQUESTED" = true ] || exit 0 ;;
  stop) ;;
  *) exit 1 ;;
esac

# The shared reader: this hook is the autosave path, and a config with a
# trailing comment or quoted path parsed to a directory that does not exist,
# which the guard below turns into a silent exit 0 — the session is simply
# never saved, with nothing said.
VAULT_PATH=$(OBSIDIAN_LOCAL_MD="$CONFIG_FILE" obsidian_config_value vault_path || true)
if [ -z "$VAULT_PATH" ] || [ ! -d "$VAULT_PATH" ]; then
  exit 0
fi

# Self-activate the vaultkeeper watcher on this host if it isn't scheduled yet.
# Cheap no-op once installed; never blocks autosave (opt out: keeper_autostart: false).
if [ "$AUTO_SAVE" != false ]; then
  . "${SCRIPT_DIR}/lib/keeper-bootstrap.sh"
  KEEPER_INTERVAL=$(grep '^keeper_interval_secs:' "$CONFIG_FILE" | head -1 | sed 's/^keeper_interval_secs:[[:space:]]*//')
  keeper_ensure_active "$CONFIG_FILE" "$VAULT_PATH" "${KEEPER_INTERVAL:-900}" || true
fi

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

SESSION_ID=$(printf '%s' "$HOOK_JSON" | python3 -c '
import json, sys
value = json.load(sys.stdin).get("session_id", "")
print(value if isinstance(value, str) else "")
') || exit 0

CAPTURE_CWD=$(printf '%s' "$HOOK_JSON" | python3 -c '
import json, sys
value = json.load(sys.stdin).get("cwd", "")
print(value if isinstance(value, str) else "")
') || exit 0

FILE_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
if [ -z "$FILE_SIZE" ] || [ "$FILE_SIZE" -lt 200 ]; then
  exit 0
fi

if ! python3 "${SCRIPT_DIR}/lib/session-capture.py" --prepare "$VAULT_PATH" "$TRANSCRIPT_PATH" "$SESSION_ID" >/dev/null; then
  exit 0
fi

# Copy transcript to a temp file so session-summarize.sh can own and delete it
TMPFILE="$(mktemp "${TMPDIR:-/tmp}/obsidian-session-XXXXXX")" || exit 0
if ! cp "$TRANSCRIPT_PATH" "$TMPFILE"; then
  rm -f "$TMPFILE"
  exit 0
fi

nohup python3 "${SCRIPT_DIR}/lib/session-capture.py" "$TMPFILE" "$CONFIG_FILE" "$VAULT_PATH" "$TRANSCRIPT_PATH" "$SESSION_ID" "$RETRY_REQUESTED" "$CAPTURE_REQUESTED" "$CAPTURE_CWD" &>/dev/null &

exit 0
