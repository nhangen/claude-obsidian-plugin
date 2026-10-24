#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
. "${ROOT_DIR}/scripts/lib/keeper-monitor.sh"
_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vk-monitor-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

export XDG_CACHE_HOME="$TMP/cache"
V="$TMP/vault"
mkdir -p "$V/.vaultkeeper-quarantine"

# 1. Non-CEO vault run: cache state recorded, no errors
keeper_monitor_tick "$V" "GAP	a.md	tags" "test-host"
CACHE_DIR="$(keeper_cache_dir "$V")"
[ -f "$CACHE_DIR/monitor.state" ] || fail "monitor.state not written to cache"
[ ! -d "$V/CEO" ] || fail "CEO directory must not be created on non-CEO vault"

# 2. CEO vault: setup CEO/alerts and CEO/inbox.md
mkdir -p "$V/CEO/alerts"
touch "$V/CEO/inbox.md"

# Quarantine is currently empty
keeper_monitor_tick "$V" "GAP	a.md	tags" "test-host"
# Quarantine is empty, so no firing alert written yet
[ ! -f "$V/CEO/alerts/vaultkeeper-quarantine.md" ] || fail "quarantine alert should not fire on empty quarantine"

# Add a quarantined conflict
echo "conflict" > "$V/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"

# Run tick: should detect transition clear -> firing
keeper_monitor_tick "$V" "GAP	a.md	tags" "test-host"
[ -f "$V/CEO/alerts/vaultkeeper-quarantine.md" ] || fail "quarantine alert file not written"
grep -q "status: firing" "$V/CEO/alerts/vaultkeeper-quarantine.md" || fail "quarantine alert should be firing"
grep -q "Resolve" "$V/CEO/inbox.md" || fail "inbox task should be created on transition"
INBOX_COUNT="$(grep -c "Resolve" "$V/CEO/inbox.md")"
[ "$INBOX_COUNT" -eq 1 ] || fail "inbox should have exactly 1 task, got $INBOX_COUNT"

# Second tick with unchanged quarantine: must NOT duplicate inbox task
keeper_monitor_tick "$V" "GAP	a.md	tags" "test-host"
INBOX_COUNT_2="$(grep -c "Resolve" "$V/CEO/inbox.md")"
[ "$INBOX_COUNT_2" -eq 1 ] || fail "unchanged tick duplicated inbox task: $INBOX_COUNT_2"

# 3. Clear quarantine; the alert rewrite keeps the alert's mode
rm -f "$V/.vaultkeeper-quarantine/"*
chmod 644 "$V/CEO/alerts/vaultkeeper-quarantine.md"
keeper_monitor_tick "$V" "GAP	a.md	tags" "test-host"
[ "$(_mode "$V/CEO/alerts/vaultkeeper-quarantine.md")" = "644" ] || fail "quarantine alert rewrite changed its mode"
grep -q "status: clear" "$V/CEO/alerts/vaultkeeper-quarantine.md" || fail "quarantine alert should transition to clear"

# 4. Gap growth alert: introduce 6 new gaps (delta >= 5)
CAND_GAPS="$(printf 'GAP\t%s\ttags\n' 1 2 3 4 5 6 7)"
keeper_monitor_tick "$V" "$CAND_GAPS" "test-host"
[ -f "$V/CEO/alerts/vaultkeeper-gaps.md" ] || fail "gaps alert not written on growth"
grep -q "status: firing" "$V/CEO/alerts/vaultkeeper-gaps.md" || fail "gaps alert should be firing on growth >= 5"
grep -q "Frontmatter gaps grew" "$V/CEO/inbox.md" || fail "gaps growth task not escalated to inbox"

# Unchanged gap tick: must NOT duplicate inbox task, and the alert rewrite keeps its mode
chmod 644 "$V/CEO/alerts/vaultkeeper-gaps.md"
keeper_monitor_tick "$V" "$CAND_GAPS" "test-host"
[ "$(_mode "$V/CEO/alerts/vaultkeeper-gaps.md")" = "644" ] || fail "gaps alert rewrite changed its mode"
GAP_INBOX_COUNT="$(grep -c "Frontmatter gaps grew" "$V/CEO/inbox.md")"
[ "$GAP_INBOX_COUNT" -eq 1 ] || fail "unchanged gap tick duplicated inbox task"

# 5. A faulted (quarantine-only) tick must not move the gap baseline, so the next healthy tick raises no false alert
V2="$TMP/vault2"; mkdir -p "$V2/.vaultkeeper-quarantine" "$V2/CEO/alerts"; touch "$V2/CEO/inbox.md"
HUNDRED="$(printf 'GAP\t%s\ttags\n' $(seq 1 100))"
keeper_monitor_tick "$V2" "$HUNDRED" "test-host"
keeper_monitor_tick "$V2" "" "test-host" quarantine-only
keeper_monitor_tick "$V2" "$HUNDRED" "test-host"
[ ! -f "$V2/CEO/alerts/vaultkeeper-gaps.md" ] || fail "fault tick poisoned the gap baseline: $(cat "$V2/CEO/alerts/vaultkeeper-gaps.md")"
grep -q "Frontmatter gaps grew" "$V2/CEO/inbox.md" && fail "false gap-growth task after a faulted tick"
# quarantine is still monitored on the faulted tick
echo "c" > "$V2/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"
keeper_monitor_tick "$V2" "" "test-host" quarantine-only
grep -q "status: firing" "$V2/CEO/alerts/vaultkeeper-quarantine.md" || fail "quarantine not monitored on a faulted tick"

# 6. A later clear -> firing transition escalates again once the earlier task was ticked off
V3="$TMP/vault3"; mkdir -p "$V3/.vaultkeeper-quarantine" "$V3/CEO/alerts"; touch "$V3/CEO/inbox.md"
QF3="$V3/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"
echo c > "$QF3"; keeper_monitor_tick "$V3" "" "test-host"
sed -i.bak 's/^- \[ \] Resolve/- [x] Resolve/' "$V3/CEO/inbox.md"; rm -f "$V3/CEO/inbox.md.bak"
rm -f "$QF3"; keeper_monitor_tick "$V3" "" "test-host"
echo c > "$QF3"; keeper_monitor_tick "$V3" "" "test-host"
[ "$(grep -c -- '^- \[ \] Resolve' "$V3/CEO/inbox.md")" -eq 1 ] || fail "second transition did not re-escalate; inbox: $(cat "$V3/CEO/inbox.md")"

# 7. A faulted tick with no saved state must not seed the gap baseline at zero
V4="$TMP/vault4"; mkdir -p "$V4/.vaultkeeper-quarantine" "$V4/CEO/alerts"; touch "$V4/CEO/inbox.md"
keeper_monitor_tick "$V4" "" "test-host" quarantine-only
keeper_monitor_tick "$V4" "$HUNDRED" "test-host"
[ ! -f "$V4/CEO/alerts/vaultkeeper-gaps.md" ] || fail "first-ever faulted tick seeded a zero gap baseline"

# 8. The inbox escalation re-checks under the lock: a line another tick appended while
# this one waited for the lock is not duplicated
V5="$TMP/vault5"; mkdir -p "$V5/.vaultkeeper-quarantine" "$V5/CEO/alerts"; touch "$V5/CEO/inbox.md"
echo c > "$V5/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"
PAUSE="$TMP/pause5"
( KEEPER_TEST_PAUSE_POINT=before_lock_owner KEEPER_TEST_PAUSE_DIR="$PAUSE" \
    keeper_monitor_tick "$V5" "" "test-host" ) &
TICK_PID=$!
for _i in $(seq 1 500); do [ -e "$PAUSE/ready" ] && break; sleep 0.01; done
[ -e "$PAUSE/ready" ] || { kill "$TICK_PID" 2>/dev/null; fail "tick never reached the inbox lock"; }
printf '\n- [ ] Resolve 1 quarantined sync conflict(s) from another tick\n' >> "$V5/CEO/inbox.md"
: > "$PAUSE/continue"
wait "$TICK_PID" || fail "paused tick failed"
[ "$(grep -c -- '^- \[ \] Resolve' "$V5/CEO/inbox.md")" -eq 1 ] \
  || fail "escalation duplicated a line appended while it waited for the lock: $(cat "$V5/CEO/inbox.md")"

# 9. With the lock held elsewhere the escalation still lands once, and says it went unlocked
V6="$TMP/vault6"; mkdir -p "$V6/.vaultkeeper-quarantine" "$V6/CEO/alerts"; touch "$V6/CEO/inbox.md"
echo c > "$V6/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"
HELD="$(keeper_lock_acquire "$(cd "$V6" && pwd -P)")" || fail "could not hold the keeper lock"
ERR6="$(KEEPER_LOCK_TIMEOUT_SECONDS=1 keeper_monitor_tick "$V6" "" "test-host" 2>&1 >/dev/null)" \
  || { keeper_lock_release "$HELD"; fail "tick failed while the lock was held: $ERR6"; }
keeper_lock_release "$HELD"
[ "$(grep -c -- '^- \[ \] Resolve' "$V6/CEO/inbox.md")" -eq 1 ] || fail "unlocked fallback did not append exactly once"
grep -qF "inbox lock unavailable" <<<"$ERR6" || fail "unlocked fallback was silent; got: $ERR6"

# 10. A symlinked CEO/inbox.md leaf must be refused, not followed (#237)
V7="$TMP/vault7"; mkdir -p "$V7/.vaultkeeper-quarantine" "$V7/CEO/alerts"
SENTINEL7="$TMP/sentinel7"; : > "$SENTINEL7"
ln -s "$SENTINEL7" "$V7/CEO/inbox.md"
echo c > "$V7/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"
ERR7="$(keeper_monitor_tick "$V7" "" "test-host" 2>&1 >/dev/null)" && fail "symlinked inbox tick reported success"
[ "$(grep -c . "$SENTINEL7")" -eq 0 ] || fail "symlinked inbox followed; outside sentinel has: $(cat "$SENTINEL7")"
grep -qF "is a symlink or does not resolve to itself" <<<"$ERR7" || fail "symlinked inbox refusal was silent; got: $ERR7"

# 10b. Once the leaf is repaired the refused transition must still refire, so the
# refused tick (which saves no state — see #237) does not eat the escalation
rm -f "$V7/CEO/inbox.md"; touch "$V7/CEO/inbox.md"
keeper_monitor_tick "$V7" "" "test-host" || fail "repaired-inbox tick failed: $?"
grep -q "Resolve" "$V7/CEO/inbox.md" || fail "refused transition never refired after leaf repair; sent: $(cat "$V7/CEO/inbox.md")"

# 11. A symlinked CEO/alerts parent must not publish quarantine alerts outside (#237)
V8="$TMP/vault8"; mkdir -p "$V8/.vaultkeeper-quarantine" "$V8/CEO"
ALERTS8="$TMP/alerts8"; mkdir -p "$ALERTS8"
ln -s "$ALERTS8" "$V8/CEO/alerts"
echo c > "$V8/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"
ERR8="$(keeper_monitor_tick "$V8" "" "test-host" 2>&1 >/dev/null)" && fail "symlinked alerts tick reported success"
[ -z "$(ls -A "$ALERTS8")" ] || fail "symlinked alerts dir received quarantine alert bytes: $(ls -A "$ALERTS8")"
grep -qF "CEO/alerts resolves outside" <<<"$ERR8" || fail "symlinked alerts refusal was silent; got: $ERR8"

# 12. A symlinked CEO/alerts parent must not publish gap alerts outside either (#237);
# a seeding tick is required or the first-ever tick just seeds the gap baseline
V9="$TMP/vault9"; mkdir -p "$V9/.vaultkeeper-quarantine" "$V9/CEO/alerts"
ALERTS9="$TMP/alerts9"; mkdir -p "$ALERTS9"
keeper_monitor_tick "$V9" "GAP	a.md	tags" "test-host" || fail "gap seeding tick failed"
rm -rf "$V9/CEO/alerts"; ln -s "$ALERTS9" "$V9/CEO/alerts"
ERR9="$(keeper_monitor_tick "$V9" "$HUNDRED" "test-host" 2>&1 >/dev/null)" && fail "symlinked gaps tick reported success"
[ -z "$(ls -A "$ALERTS9")" ] || fail "symlinked alerts dir received gap alert bytes: $(ls -A "$ALERTS9")"
grep -qF "CEO/alerts resolves outside" <<<"$ERR9" || fail "symlinked gaps refusal was silent; got: $ERR9"

# 13. A symlinked CEO itself is caught by the same guard, for the whole parent chain:
# quarantine alert and inbox escalation stay off the resolved target.
# The outside target mirrors the attacker's shape (their own alerts/ and inbox.md) so
# the tick would publish there if the guard did not refuse it. The alerts guard refuses
# first, so this pins the quarantine alert and inbox only; the inbox guard is pinned by 14.
V10="$TMP/vault10"; mkdir -p "$V10/.vaultkeeper-quarantine" "$V10/CEO/alerts"
CEO10="$TMP/ceo10"; mkdir -p "$CEO10/alerts"; : > "$CEO10/inbox.md"
rm -rf "$V10/CEO"; ln -s "$CEO10" "$V10/CEO"
echo c > "$V10/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"
ERR10="$(keeper_monitor_tick "$V10" "$HUNDRED" "test-host" 2>&1 >/dev/null)" && fail "symlinked CEO tick reported success"
[ -z "$(ls -A "$CEO10/alerts")" ] || fail "symlinked CEO received alert files: $(ls -A "$CEO10/alerts")"
[ ! -s "$CEO10/inbox.md" ] || fail "symlinked CEO received inbox escalation bytes"
grep -qF "CEO/alerts resolves outside" <<<"$ERR10" || fail "symlinked CEO refusal was silent; got: $ERR10"

# 14. The inbox guard on its own: a CEO that resolves elsewhere, an inbox leaf symlink,
# and a missing parent are each refused, and a real inbox passes. The tick never reaches
# the inbox guard behind a symlinked CEO (13), so call it directly.
V11="$TMP/vault11"; mkdir -p "$V11/CEO"; : > "$V11/CEO/inbox.md"
C11="$(cd "$V11" && pwd -P)"
_km_inbox_guarded "$C11" "$C11/CEO/inbox.md" || fail "real inbox refused by guard"
V12="$TMP/vault12"; mkdir -p "$V12"; OUT12="$TMP/out12"; mkdir -p "$OUT12"; : > "$OUT12/inbox.md"
ln -s "$OUT12" "$V12/CEO"; C12="$(cd "$V12" && pwd -P)"
! _km_inbox_guarded "$C12" "$C12/CEO/inbox.md" || fail "symlinked CEO passed inbox guard"
V13="$TMP/vault13"; mkdir -p "$V13"; C13="$(cd "$V13" && pwd -P)"
! _km_inbox_guarded "$C13" "$C13/CEO/inbox.md" || fail "missing CEO passed inbox guard"

# 15. The under-lock re-guard returns 3 and leaves an outside target untouched, and the
# escalate wrapper surfaces a refusal as 3 (not the 1 an append failure returns)
V14="$TMP/vault14"; mkdir -p "$V14/CEO"; S14="$TMP/sentinel14"; : > "$S14"
ln -s "$S14" "$V14/CEO/inbox.md"; C14="$(cd "$V14" && pwd -P)"
RC15=0; _km_inbox_escalate_locked "$C14" "$C14/CEO/inbox.md" '^- ' '- [ ] x' || RC15=$?
[ "$RC15" -eq 3 ] || fail "locked escalate on symlinked leaf returned $RC15, want 3"
RC15=0; _km_inbox_escalate "$C14" '^- ' '- [ ] x' 2>/dev/null || RC15=$?
[ "$RC15" -eq 3 ] || fail "escalate on symlinked leaf returned $RC15, want 3"
[ ! -s "$S14" ] || fail "outside sentinel received bytes: $(cat "$S14")"

# 16. A failed inbox append is not a refusal: the tick fails but still saves state
# (#237 withholds state only for refused destinations)
if [ "$(id -u)" -ne 0 ]; then
  V15="$TMP/vault15"; mkdir -p "$V15/.vaultkeeper-quarantine" "$V15/CEO/alerts"
  : > "$V15/CEO/inbox.md"; chmod 444 "$V15/CEO/inbox.md"
  echo c > "$V15/.vaultkeeper-quarantine/1700000000-Pending.sync-conflict-20261010-010101-MBP.md"
  ERR16="$(keeper_monitor_tick "$V15" "" "test-host" 2>&1 >/dev/null)" && fail "unwritable inbox tick reported success"
  ! grep -qF "alert destinations refused" <<<"$ERR16" || fail "append failure reported as a refusal; got: $ERR16"
  [ -f "$(keeper_cache_dir "$V15")/monitor.state" ] || fail "state not saved after an append failure"
  chmod 644 "$V15/CEO/inbox.md"
fi

echo "PASS: vaultkeeper-monitor"
