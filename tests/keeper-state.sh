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
# An absent last_scan is NOT healthy (#52). The tick withholds last_scan when a
# scan faults, so a host whose first scan ever faulted has none — and the old
# behaviour (silence) made that indistinguishable from a fresh successful scan,
# permanently. The cache dir exists here because keeper_state_init ran above,
# which is the same condition a real tick establishes.
COLD="$(staleness_banner "$VAULT" 900)"
[ -n "$COLD" ] \
  || fail "a host that has never recorded a scan reported nothing wrong"
case "$COLD" in
  *never*) : ;;
  *) fail "cold start must say it has never scanned, not reuse the stale wording: $COLD" ;;
esac
# …but a vault the keeper has never touched is not a fault, and must stay quiet.
UNTOUCHED="$TMP/untouched"; mkdir -p "$UNTOUCHED"
[ -z "$(staleness_banner "$UNTOUCHED" 900)" ] \
  || fail "warned about a vault where the keeper has never run: $(staleness_banner "$UNTOUCHED" 900)"
keeper_record_scan "$VAULT"
[ -n "$(keeper_last_scan "$VAULT")" ] || fail "last_scan not recorded"
[ -z "$(staleness_banner "$VAULT" 900)" ] || fail "fresh scan should not warn"
# force stale: last_scan far in the past (> 2*interval)
printf '1000\n' > "$(keeper_cache_dir "$VAULT")/last_scan"
[ -n "$(staleness_banner "$VAULT" 900)" ] || fail "stale scan should warn"

# A corrupt last_scan must be reported, not silently compared. The arithmetic
# below it would otherwise abort the caller — ask-staleness.sh runs under set -e.
printf 'not-a-number\n' > "$(keeper_cache_dir "$VAULT")/last_scan"
BAD="$(staleness_banner "$VAULT" 900)" || fail "an unreadable last_scan aborted staleness_banner"
case "$BAD" in
  *unreadable*) : ;;
  *) fail "an unreadable last_scan produced no distinct warning: ${BAD:-<empty>}" ;;
esac

echo "PASS: keeper-state"
