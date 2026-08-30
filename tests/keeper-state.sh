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

# --- degraded state files: empty is not absent, and absent is not healthy (#94) ---
#
# `>` truncates on open and can then fail on write, so a zero-byte state file is
# exactly what ENOSPC leaves behind — the disk shape the #49 fd/disk gate was
# written for. Reading it through `cat` alone made it indistinguishable from a
# file that was never written.

# keeper_read_ts tells the three states apart, which is what the banner branches on.
RT="$TMP/rt"; mkdir -p "$RT"
RC=0; keeper_read_ts "$RT/absent" >/dev/null || RC=$?
[ "$RC" = "1" ] || fail "a missing state file must read as absent (rc 1), got rc $RC"
: > "$RT/empty"
RC=0; keeper_read_ts "$RT/empty" >/dev/null || RC=$?
[ "$RC" = "2" ] || fail "a zero-byte state file must read as unparseable (rc 2), got rc $RC"
printf 'abc\n' > "$RT/junk"
RC=0; keeper_read_ts "$RT/junk" >/dev/null || RC=$?
[ "$RC" = "2" ] || fail "a non-numeric state file must read as unparseable (rc 2), got rc $RC"
printf '1712345678\n' > "$RT/good"
[ "$(keeper_read_ts "$RT/good")" = "1712345678" ] || fail "a valid timestamp did not read back"

# An empty last_scan alongside a valid attempt used to print "never completed a
# scan" on a host that had just completed one — loud, and wrong.
keeper_record_attempt "$VAULT"
: > "$(keeper_last_scan_file "$VAULT")"
EMPTY_SCAN="$(staleness_banner "$VAULT" 900)" \
  || fail "an empty last_scan aborted staleness_banner"
case "$EMPTY_SCAN" in
  *unreadable*) : ;;
  *never*) fail "an empty last_scan was reported as a host that never scanned: $EMPTY_SCAN" ;;
  *) fail "an empty last_scan produced no distinct warning: ${EMPTY_SCAN:-<empty>}" ;;
esac

# The mirror case: an empty last_attempt with no last_scan used to take the
# never-attempted branch and stay silent on a host that has attempted and never
# completed — back in the silence #52 removed.
rm -f "$(keeper_last_scan_file "$VAULT")"
: > "$(keeper_last_attempt_file "$VAULT")"
EMPTY_ATT="$(staleness_banner "$VAULT" 900)" \
  || fail "an empty last_attempt aborted staleness_banner"
case "$EMPTY_ATT" in
  *unreadable*) : ;;
  *) fail "an empty last_attempt read as 'nothing has tried here': ${EMPTY_ATT:-<empty>}" ;;
esac

# Recording stages and swaps, so a state file is never observed half-written and
# no temp file is left in the cache dir.
rm -f "$(keeper_last_attempt_file "$VAULT")"
keeper_record_scan "$VAULT" || fail "keeper_record_scan failed"
[ -n "$(keeper_last_scan "$VAULT")" ] || fail "record_scan wrote no timestamp"
STRAY="$(find "$(keeper_cache_dir "$VAULT")" -maxdepth 1 -name '.ts-*' | wc -l | tr -d ' ')"
[ "$STRAY" = "0" ] || fail "record_scan left $STRAY staged temp file(s) behind"

# A cache dir that cannot be written reports the failure rather than claiming a
# scan the tick could not account for (vaultkeeper-tick.sh branches on this rc).
if [ "$(id -u)" = "0" ]; then
  printf 'skip: unwritable-cache-dir assertion (running as root ignores 0555)\n' >&2
else
  chmod 555 "$(keeper_cache_dir "$VAULT")"
  keeper_record_attempt "$VAULT" 2>/dev/null \
    && { chmod 755 "$(keeper_cache_dir "$VAULT")"; fail "recording into an unwritable cache dir reported success"; }
  chmod 755 "$(keeper_cache_dir "$VAULT")"
fi

# --- a deferring host speaks from the vault's evidence (#95) -----------------
#
# Keeper state is per-host and never synced, and only the elected owner scans,
# so a deferring host has neither a scan nor an attempt — and stayed silent
# whether the owner was healthy or had faulted on every tick since install. On
# a two-host vault that host is usually where /obsidian:ask is run.
. "${ROOT_DIR}/scripts/lib/keeper-lease.sh"
DEF="$TMP/deferring"; mkdir -p "$DEF"
[ -z "$(keeper_last_scan "$DEF")" ] && [ -z "$(keeper_last_attempt "$DEF")" ] \
  || fail "fixture precondition: the deferring host must have no local state"

# A vault no host has ever claimed is not a fault: the keeper has never run
# anywhere, and this host has nothing to report.
[ -z "$(staleness_banner "$DEF" 900)" ] \
  || fail "warned about a vault the keeper has never run on: $(staleness_banner "$DEF" 900)"

# With a live claim and no digest at all, no host has ever completed a scan.
keeper_claim_write "$DEF/.vaultkeeper" "ml-1"
NODIGEST="$(staleness_banner "$DEF" 900 "ml-1,mbp")"
case "$NODIGEST" in
  *"no host has produced"*) : ;;
  *) fail "a claimed vault with no digest reported nothing: ${NODIGEST:-<empty>}" ;;
esac
case "$NODIGEST" in
  *"ml-1"*) : ;;
  *) fail "the vault-sourced banner did not name the elected owner: $NODIGEST" ;;
esac

# The owner stamps scan_status: INCOMPLETE into Librarian.md on every faulted
# tick. That is the signal the deferring host was blind to.
printf '# Librarian\n\nlast_scan: %s\nscan_status: INCOMPLETE\n' "$(now_epoch)" > "$DEF/Librarian.md"
FAULTING="$(staleness_banner "$DEF" 900 "ml-1,mbp")"
case "$FAULTING" in
  *faulted*ml-1*) : ;;
  *) fail "the owner's faulting scans were invisible to the deferring host: ${FAULTING:-<empty>}" ;;
esac

# A healthy owner must stay quiet here — a banner that always fires carries no
# information, which is the failure mode the obvious hoist-the-attempt fix has.
printf '# Librarian\n\nlast_scan: %s\n' "$(now_epoch)" > "$DEF/Librarian.md"
[ -z "$(staleness_banner "$DEF" 900 "ml-1,mbp")" ] \
  || fail "warned on a vault the owner is scanning fine: $(staleness_banner "$DEF" 900 "ml-1,mbp")"

# A digest nobody refreshes is what a dead owner leaves: it never gets to stamp
# INCOMPLETE. Same 2x grace the local branch allows.
printf '# Librarian\n\nlast_scan: 1000\n' > "$DEF/Librarian.md"
STALE_DIGEST="$(staleness_banner "$DEF" 900 "ml-1,mbp")"
case "$STALE_DIGEST" in
  *"last maintained"*) : ;;
  *) fail "a digest no host has refreshed reported nothing: ${STALE_DIGEST:-<empty>}" ;;
esac

# An unparseable digest is a state to report, not one to fall silent on — and
# the arithmetic on it must not abort the caller.
printf '# Librarian\n\nlast_scan: not-a-number\n' > "$DEF/Librarian.md"
BADDIGEST="$(staleness_banner "$DEF" 900 "ml-1,mbp")" \
  || fail "an unreadable digest aborted staleness_banner"
case "$BADDIGEST" in
  *unreadable*) : ;;
  *) fail "an unreadable digest produced no warning: ${BADDIGEST:-<empty>}" ;;
esac

# This host's own state still wins when it has any: the vault fallback is for
# hosts with nothing local to speak from, not a second opinion over one.
keeper_record_scan "$DEF"
[ -z "$(staleness_banner "$DEF" 900 "ml-1,mbp")" ] \
  || fail "a host with a fresh local scan was overruled by the vault digest"

echo "PASS: keeper-state"
