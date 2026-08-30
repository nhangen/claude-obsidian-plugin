#!/usr/bin/env bash
# ask-staleness.sh — print a staleness banner for /obsidian:ask when the
# vaultkeeper index has not been maintained within 2x the configured interval.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/keeper-state.sh"
. "${ROOT}/lib/resolve-config.sh"

CONFIG="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}")" || exit 0
VAULT="$(grep '^vault_path:' "$CONFIG" | head -1 | sed 's/vault_path: *//')"
[ -n "$VAULT" ] || exit 0
INTERVAL="$(grep '^keeper_interval_secs:' "$CONFIG" | head -1 | sed 's/.*: *//')"
INTERVAL="${INTERVAL:-900}"
# Do not let the check's own failure read as a clean bill of health: every
# consumer keys off stdout alone ("if it prints a line, show it"), and this
# script's set -e would otherwise exit 1 with nothing printed (#94).
staleness_banner "$VAULT" "$INTERVAL" || printf '⚠ could not determine index freshness\n'
