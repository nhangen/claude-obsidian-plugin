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
# The cache dir alone is not evidence that anything tried to scan. keeper_state_init
# creates it at the top of every tick — above the ownership gate — so it exists on a
# host that only ever defers to the elected owner. Keying the warning off it warned
# there on every ask, forever, about a vault the owner was scanning fine.
[ -z "$(keeper_last_attempt "$VAULT")" ] || fail "last_attempt should be empty"
[ -d "$(keeper_cache_dir "$VAULT")" ] || fail "fixture precondition: cache dir should exist here"
[ -z "$(staleness_banner "$VAULT" 900)" ] \
  || fail "warned with only a cache dir to go on: $(staleness_banner "$VAULT" 900)"

# An absent last_scan IS a fault once something has attempted a scan (#52). The tick
# withholds last_scan when a scan faults, so a host whose first scan ever faulted has
# an attempt and no scan — and the old behaviour (silence) made that indistinguishable
# from a fresh successful scan, permanently.
keeper_record_attempt "$VAULT"
[ -n "$(keeper_last_attempt "$VAULT")" ] || fail "last_attempt not recorded"
COLD="$(staleness_banner "$VAULT" 900)"
[ -n "$COLD" ] \
  || fail "a host that attempted a scan and never completed one reported nothing wrong"
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

# Same for last_attempt, which the absent-last_scan branch now does arithmetic on.
# A truncated or partially-written epoch there would otherwise abort the caller in the
# one state this warning exists to describe.
rm -f "$(keeper_last_scan_file "$VAULT")"
printf 'not-a-number\n' > "$(keeper_last_attempt_file "$VAULT")"
BADA="$(staleness_banner "$VAULT" 900)" || fail "an unreadable last_attempt aborted staleness_banner"
case "$BADA" in
  *unreadable*) : ;;
  *) fail "an unreadable last_attempt produced no distinct warning: ${BADA:-<empty>}" ;;
esac

echo "PASS: keeper-state"
