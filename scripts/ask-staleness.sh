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
# obsidian_config_value, not a local grep/sed: an abort here prints nothing,
# which every consumer reads as a healthy index (#94) — and a hand-rolled read
# keeps the quotes, so a config with `vault_path: "/vault"` sent a $VAULT that
# matches no directory into keeper_vault_health, which then took its
# "no host has ever claimed this vault, stay quiet" branch and hid a faulting
# owner. Same shape one layer on for a quoted keeper_interval_secs.
# `|| true`: an absent key returns 1, and each has a default below.
VAULT="$(obsidian_config_value vault_path || true)"
[ -n "$VAULT" ] || exit 0
INTERVAL="$(obsidian_config_value keeper_interval_secs || true)"
INTERVAL="${INTERVAL:-900}"
PRIORITY="$(obsidian_config_value keeper_host_priority | tr ' ' ',' || true)"
# Do not let the check's own failure read as a clean bill of health: every
# consumer keys off stdout alone ("if it prints a line, show it"), and this
# script's set -e would otherwise exit 1 with nothing printed (#94).
staleness_banner "$VAULT" "$INTERVAL" "$PRIORITY" || printf '⚠ could not determine index freshness\n'
