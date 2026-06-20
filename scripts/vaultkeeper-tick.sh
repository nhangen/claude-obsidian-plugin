#!/usr/bin/env bash
# vaultkeeper-tick.sh — one deterministic substrate tick (no LLM). Runs on
# cron (ML-1) / launchd (MBP). Owner-gated shared writes; quarantine + scan +
# surface only as the elected owner. State is non-synced (under XDG cache).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/frontmatter.sh"
. "${ROOT}/lib/vault-scan.sh"
. "${ROOT}/lib/base-views.sh"
. "${ROOT}/lib/keeper-state.sh"
. "${ROOT}/lib/keeper-lease.sh"
. "${ROOT}/lib/surfacing.sh"
. "${ROOT}/lib/resolve-config.sh"

CONFIG="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}")" || {
  echo "vaultkeeper: no config; run /obsidian:setup" >&2; exit 0; }

cfg_val() { grep "^$1:" "$CONFIG" | head -1 | sed "s/^$1: *//"; }
VAULT="$(cfg_val vault_path)"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || { echo "vaultkeeper: vault not found: $VAULT" >&2; exit 0; }

REQUIRED="$(cfg_val frontmatter_required)"; REQUIRED="${REQUIRED:-tags type}"
PRIORITY="$(cfg_val keeper_host_priority | tr ' ' ',')"
INTERVAL="$(cfg_val keeper_interval_secs)"; INTERVAL="${INTERVAL:-900}"
MAXAGE=$(( INTERVAL * 2 ))
HOST="${VAULTKEEPER_HOST:-$(hostname -s)}"
LEASE="$VAULT/.vaultkeeper"

keeper_state_init "$VAULT" >/dev/null
keeper_claim_write "$LEASE" "$HOST"

if ! keeper_is_owner "$LEASE" "$HOST" "$PRIORITY" "$MAXAGE"; then
  echo "vaultkeeper: $HOST defers to $(keeper_elect "$LEASE" "$PRIORITY" "$MAXAGE")" >&2
  exit 0
fi

CONFLICTS="$(keeper_quarantine_conflicts "$VAULT" || true)"
CAND="$( {
  scan_frontmatter_gaps "$VAULT" "$REQUIRED"
  scan_unfiled "$VAULT"
  scan_open_asks "$VAULT"
  scan_clusters "$VAULT" 3
  if [ -n "$CONFLICTS" ]; then printf '%s\n' "$CONFLICTS"; fi
} | sed '/^$/d' )"

base_view_write "$VAULT/_vaultkeeper.base"
printf '%s\n' "$CAND" | surfacing_digest "$VAULT"
printf '%s\n' "$CAND" | surfacing_pending_transition "$VAULT"
keeper_record_scan "$VAULT"
echo "vaultkeeper: scan complete ($HOST)"
