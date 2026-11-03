#!/usr/bin/env bash
set -euo pipefail
: "${OBSIDIAN_PUBLIC_CLIENT_SOURCE:?point to the public obsidian-mcp f511884 source checkout}"
export PYTHONDONTWRITEBYTECODE=1
exec python3 -B "$(cd "$(dirname "$0")" && pwd)/codex-capture-activation.test.py" "$@"
