#!/usr/bin/env bash
# TEST-TYPE: enforcement

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/obsidian-mcp-client-lifecycle.test.py" || exit 1
