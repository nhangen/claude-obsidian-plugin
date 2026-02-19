#!/usr/bin/env bash
# Opens a vault file in the Windows Obsidian GUI via URI scheme.
# Usage: open-in-obsidian.sh <relative-path-in-vault>
# Example: open-in-obsidian.sh "Projects/Development/Claude-WSL/2026-02-19-session.md"

VAULT_NAME="Obsidian"
FILE_PATH="${1}"

if [ -z "$FILE_PATH" ]; then
  echo "Usage: $0 <relative-vault-path>"
  exit 1
fi

# URL-encode the file path (spaces → %20, etc.)
ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${FILE_PATH}'))")

URI="obsidian://open?vault=${VAULT_NAME}&file=${ENCODED}"

# Check if obsidian process is running on Windows side
OBSIDIAN_RUNNING=$(tasklist.exe 2>/dev/null | grep -i "obsidian" | wc -l)

if [ "$OBSIDIAN_RUNNING" -gt 0 ]; then
  cmd.exe /c start "" "${URI}" 2>/dev/null
  echo "Opened in Obsidian: ${FILE_PATH}"
else
  echo "Obsidian not running — note saved at: ~/obsidian/${FILE_PATH}"
fi
