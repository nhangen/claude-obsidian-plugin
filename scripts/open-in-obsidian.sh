#!/usr/bin/env bash
# Opens a vault file in the Obsidian GUI via URI scheme.
# Usage: open-in-obsidian.sh <relative-path-in-vault>
# Example: open-in-obsidian.sh "Projects/Development/2026-02-19-session.md"
# Supports macOS and Windows/WSL.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PLUGIN_ROOT}/obsidian.local.md"

FILE_PATH="${1}"

if [ -z "$FILE_PATH" ]; then
  echo "Usage: $0 <relative-vault-path>"
  exit 1
fi

# Read vault_name from config; fall back to "Obsidian"
VAULT_NAME="Obsidian"
if [ -f "$CONFIG_FILE" ]; then
  PARSED=$(grep '^vault_name:' "$CONFIG_FILE" | head -1 | sed 's/^vault_name:[[:space:]]*//')
  [ -n "$PARSED" ] && VAULT_NAME="$PARSED"
fi

# URL-encode both vault name and file path (spaces → %20, etc.)
ENCODED_VAULT=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$VAULT_NAME")
ENCODED_FILE=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$FILE_PATH")

URI="obsidian://open?vault=${ENCODED_VAULT}&file=${ENCODED_FILE}"

case "$(uname -s)" in
  Darwin)
    open "$URI" 2>/dev/null && echo "Opened in Obsidian: ${FILE_PATH}" || echo "Note saved; could not open GUI (is Obsidian installed?)"
    ;;
  Linux)
    # WSL: delegate to Windows via cmd.exe
    if grep -qi microsoft /proc/version 2>/dev/null; then
      OBSIDIAN_RUNNING=$(tasklist.exe 2>/dev/null | grep -ci "obsidian" || true)
      if [ "$OBSIDIAN_RUNNING" -gt 0 ]; then
        cmd.exe /c start "" "${URI}" 2>/dev/null
        echo "Opened in Obsidian: ${FILE_PATH}"
      else
        echo "Obsidian not running — note saved at: ${FILE_PATH}"
      fi
    else
      echo "Note saved; GUI open not supported on this platform"
    fi
    ;;
  *)
    echo "Note saved; GUI open not supported on this platform"
    ;;
esac
