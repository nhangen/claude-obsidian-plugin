#!/usr/bin/env bash
# ask-staleness.sh — print a staleness banner for /obsidian:ask when the
# vaultkeeper index has not been maintained within 2x the configured interval.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/keeper-state.sh"
# Sourced so the banner can name the elected owner when it has to speak from
# the vault's evidence rather than this host's (#95).
. "${ROOT}/lib/keeper-lease.sh"
. "${ROOT}/lib/resolve-config.sh"

CONFIG="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}")" || exit 0
# Every one of these is an unmatched-grep away from a failed pipeline under this
# script's pipefail, and an abort here prints nothing — which every consumer
# reads as a healthy index (#94). keeper_interval_secs is the live case: the
# setup wizard's config template does not write it, so on a default install the
# freshness check aborted one line before the guard meant to protect it, and the
# `[ -n "$VAULT" ]` test below was dead code.
cfg_val() { grep "^$1:" "$CONFIG" | head -1 | sed "s/^$1:[[:space:]]*//" || true; }
VAULT="$(cfg_val vault_path)"
[ -n "$VAULT" ] || exit 0
INTERVAL="$(cfg_val keeper_interval_secs)"
INTERVAL="${INTERVAL:-900}"
PRIORITY="$(cfg_val keeper_host_priority | tr ' ' ',')"
# Do not let the check's own failure read as a clean bill of health: every
# consumer keys off stdout alone ("if it prints a line, show it"), and this
# script's set -e would otherwise exit 1 with nothing printed (#94).
staleness_banner "$VAULT" "$INTERVAL" "$PRIORITY" || printf '⚠ could not determine index freshness\n'
