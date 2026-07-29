#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-state-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
VAULT="$TMP/vault"; mkdir -p "$VAULT"

# vault-id is stable and 16 hex chars
ID1="$(keeper_vault_id "$VAULT")"
ID2="$(keeper_vault_id "$VAULT")"
[ "$ID1" = "$ID2" ] || fail "vault id not stable"
[[ "$ID1" =~ ^[0-9a-f]{16}$ ]] || fail "vault id not 16 hex: $ID1"

# cache dir is under XDG_CACHE_HOME, NOT under the vault (state-not-in-vault invariant)
CDIR="$(keeper_cache_dir "$VAULT")"
case "$CDIR" in "$XDG_CACHE_HOME"/vaultkeeper/*) : ;; *) fail "cache dir wrong: $CDIR" ;; esac
case "$CDIR" in "$VAULT"/*) fail "cache dir is inside vault: $CDIR" ;; esac

keeper_state_init "$VAULT" >/dev/null
[ -d "$CDIR" ] || fail "state_init did not create cache dir"

# cold start: no snapshot
keeper_has_snapshot "$VAULT" && fail "snapshot should not exist yet"
[ -z "$(keeper_read_snapshot "$VAULT")" ] || fail "cold read should be empty"

# write + read snapshot (sorted, deduped)
printf 'b\na\na\n' | keeper_write_snapshot "$VAULT"
keeper_has_snapshot "$VAULT" || fail "snapshot should exist after write"
[ "$(keeper_read_snapshot "$VAULT")" = "$(printf 'a\nb')" ] || fail "snapshot not sorted/deduped"

# last_scan + staleness
[ -z "$(keeper_last_scan "$VAULT")" ] || fail "last_scan should be empty"
[ -z "$(staleness_banner "$VAULT" 900)" ] || fail "no banner when last_scan absent"
keeper_record_scan "$VAULT"
[ -n "$(keeper_last_scan "$VAULT")" ] || fail "last_scan not recorded"
[ -z "$(staleness_banner "$VAULT" 900)" ] || fail "fresh scan should not warn"
# force stale: last_scan far in the past (> 2*interval)
printf '1000\n' > "$(keeper_cache_dir "$VAULT")/last_scan"
[ -n "$(staleness_banner "$VAULT" 900)" ] || fail "stale scan should warn"

# --- a host that has ATTEMPTED a scan but never completed one is not healthy (#52) ---
# The scan-fault gate withholds last_scan on purpose, so a host whose scans fault
# from the very first tick never records one. The banner's `[ -z "$last" ] && return 0`
# then made that host indistinguishable from one scanned a second ago — the fault
# latched silently. `keeper_last_scan` absent is two different states, and only one
# of them (never attempted: fresh install, or a non-owner host that defers before
# scanning) warrants silence.
AV="$TMP/attempted"; mkdir -p "$AV"
keeper_state_init "$AV" >/dev/null
[ -z "$(keeper_last_attempt "$AV")" ] || fail "last_attempt should be empty before any tick"
[ -z "$(staleness_banner "$AV" 900)" ] || fail "never-attempted host must stay silent"
keeper_record_attempt "$AV"
[ -n "$(keeper_last_attempt "$AV")" ] || fail "last_attempt not recorded"
BANNER="$(staleness_banner "$AV" 900)"
[ -n "$BANNER" ] || fail "attempted-but-never-completed host must warn, got silence"
case "$BANNER" in *"never completed"*) : ;; *) fail "banner must say the scan never completed: $BANNER" ;; esac
# A completed scan wins over the attempt: recording one must silence the never-completed line.
keeper_record_scan "$AV"
[ -z "$(staleness_banner "$AV" 900)" ] || fail "fresh completed scan should not warn even with an attempt on disk"

echo "PASS: keeper-state"
