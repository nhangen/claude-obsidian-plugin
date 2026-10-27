#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVENT="${1:?hook event required}"
LEGACY=""
case "$EVENT" in
  SessionStart) LEGACY="$SCRIPT_DIR/config-doctor.sh" ;;
  Stop) LEGACY="$SCRIPT_DIR/session-save.sh" ;;
  PreToolUse) LEGACY="$SCRIPT_DIR/commit-capture-pre.sh" ;;
  PostToolUse) LEGACY="$SCRIPT_DIR/commit-capture.sh" ;;
  UserPromptSubmit|PostToolUseFailure|StopFailure) ;;
  *) printf 'capture-hook: unsupported hook event\n' >&2; exit 2 ;;
esac
if [ -n "$LEGACY" ]; then
  exec python3 "$SCRIPT_DIR/lib/capture-owner.py" route --event "$EVENT" --script "$LEGACY"
fi
exec python3 "$SCRIPT_DIR/lib/capture-owner.py" route --event "$EVENT"
