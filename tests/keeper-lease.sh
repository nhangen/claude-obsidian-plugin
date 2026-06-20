#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-lease.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-lease-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
L="$TMP/.vaultkeeper"

# Two fully-synced claims; priority ml-1 > mbp -> ml-1 owns, deterministically
# from BOTH hosts' point of view (same claim set => same owner).
keeper_claim_write "$L" "ml-1"
keeper_claim_write "$L" "mbp"
[ "$(keeper_elect "$L" "ml-1,mbp")" = "ml-1" ] || fail "ml-1 should win by priority"
keeper_is_owner "$L" "ml-1" "ml-1,mbp" || fail "ml-1 should be owner"
keeper_is_owner "$L" "mbp"  "ml-1,mbp" && fail "mbp must NOT be owner (defers)"

# Partially-propagated claim set (follow-up #2): ml-1's claim has NOT yet synced
# to this host; only mbp and mac-2 are visible. Election must still be
# deterministic over the present set, and the loser writes nothing.
L2="$TMP/.vk2"
keeper_claim_write "$L2" "mbp"
keeper_claim_write "$L2" "mac-2"
OWNER="$(keeper_elect "$L2" "ml-1,mbp")"   # ml-1 absent -> highest present priority = mbp
[ "$OWNER" = "mbp" ] || fail "with ml-1 absent, mbp should own present set: $OWNER"
keeper_is_owner "$L2" "mac-2" "ml-1,mbp" && fail "mac-2 must defer in partial set"

# No priority list: lexicographically lowest live host wins (still deterministic).
L3="$TMP/.vk3"
keeper_claim_write "$L3" "zeta"
keeper_claim_write "$L3" "alpha"
[ "$(keeper_elect "$L3" "")" = "alpha" ] || fail "lexicographic fallback should pick alpha"

# Stale claim is ignored when max_age is given.
L4="$TMP/.vk4"; mkdir -p "$L4"
printf '1000\n' > "$L4/.keeper-claim-old"        # ancient
keeper_claim_write "$L4" "fresh"
[ "$(keeper_elect "$L4" "" 86400)" = "fresh" ] || fail "stale claim should be excluded"

# Quarantine: a planted .sync-conflict on Librarian.md is moved aside, surfaced,
# and NEVER deleted.
V="$TMP/vault"; mkdir -p "$V"
printf 'digest\n' > "$V/Librarian.md"
CONFLICT="$V/Librarian.sync-conflict-20260620-120000-ABCDEFG.md"
printf 'conflicted copy\n' > "$CONFLICT"
OUT="$(keeper_quarantine_conflicts "$V")"
grep -q "QUARANTINE"$'\t'"Librarian.sync-conflict" <<<"$OUT" || fail "conflict not surfaced"
[ ! -e "$CONFLICT" ] || fail "conflict not moved out of vault root"
[ "$(find "$V/.vaultkeeper-quarantine" -name '*Librarian.sync-conflict*' | wc -l | tr -d ' ')" = "1" ] \
  || fail "conflict not preserved in quarantine (data loss)"
[ -f "$V/Librarian.md" ] || fail "canonical Librarian.md must be untouched"

# Quarantine: non-keeper conflict is left in place; Pending keeper conflict is quarantined.
# Single keeper_quarantine_conflicts call processes all conflicts at once.
V2="$TMP/vault2"; mkdir -p "$V2"
NONKEEPER="$V2/MyNote.sync-conflict-20260620-120000-ABCDEFG.md"
KEEPER_CONFLICT="$V2/Pending.sync-conflict-20260620-120000-ABCDEFG.md"
printf 'non-keeper conflict\n' > "$NONKEEPER"
printf 'pending keeper conflict\n' > "$KEEPER_CONFLICT"
OUT2="$(keeper_quarantine_conflicts "$V2")"
# non-keeper: still at original path, not in quarantine dir, not in output
[ -e "$NONKEEPER" ] || fail "MyNote conflict must remain at original path"
[ "$(find "$V2/.vaultkeeper-quarantine" -name '*MyNote*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || fail "MyNote conflict must NOT be under quarantine"
grep -q "MyNote" <<<"$OUT2" && fail "MyNote must NOT appear in QUARANTINE output"
# keeper (Pending): surfaced, moved out of root, preserved in quarantine
grep -q "QUARANTINE"$'\t'"Pending.sync-conflict" <<<"$OUT2" || fail "Pending conflict not surfaced"
[ ! -e "$KEEPER_CONFLICT" ] || fail "Pending conflict not moved out of vault root"
[ "$(find "$V2/.vaultkeeper-quarantine" -name '*Pending.sync-conflict*' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  || fail "Pending conflict not preserved in quarantine (data loss)"

echo "PASS: keeper-lease"
