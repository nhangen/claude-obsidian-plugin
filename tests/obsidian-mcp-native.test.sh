#!/usr/bin/env bash
# TEST-TYPE: regression
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/obsidian-mcp-native.test.py" || exit 1
