#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
. "${ROOT_DIR}/scripts/lib/keeper-monitor.sh"
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

# 3. Clear quarantine
rm -f "$V/.vaultkeeper-quarantine/"*
keeper_monitor_tick "$V" "GAP	a.md	tags" "test-host"
grep -q "status: clear" "$V/CEO/alerts/vaultkeeper-quarantine.md" || fail "quarantine alert should transition to clear"

# 4. Gap growth alert: introduce 6 new gaps (delta >= 5)
CAND_GAPS="$(printf 'GAP\t%s\ttags\n' 1 2 3 4 5 6 7)"
keeper_monitor_tick "$V" "$CAND_GAPS" "test-host"
[ -f "$V/CEO/alerts/vaultkeeper-gaps.md" ] || fail "gaps alert not written on growth"
grep -q "status: firing" "$V/CEO/alerts/vaultkeeper-gaps.md" || fail "gaps alert should be firing on growth >= 5"
grep -q "Frontmatter gaps grew" "$V/CEO/inbox.md" || fail "gaps growth task not escalated to inbox"

# Unchanged gap tick: must NOT duplicate inbox task
keeper_monitor_tick "$V" "$CAND_GAPS" "test-host"
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

echo "PASS: vaultkeeper-monitor"
