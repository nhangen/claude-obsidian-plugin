#!/usr/bin/env bash
# TEST-TYPE: regression
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)" || exit 1
test -n "$tmp" && test -d "$tmp" || exit 1
trap 'rm -rf "$tmp"' EXIT

python3 "$ROOT/scripts/pack-obsidian-mcp-client.py" --output "$tmp/client" || exit 1
OBSIDIAN_MCP_EVENT_BIN="$tmp/client/bin/obsidian-mcp-commit-event" \
  python3 "$ROOT/tests/obsidian-mcp-commit-event.test.py" || exit 1
