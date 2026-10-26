#!/usr/bin/env bash
# TEST-TYPE: regression
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tests/obsidian-mcp-build-validation.test.py" || exit 1
