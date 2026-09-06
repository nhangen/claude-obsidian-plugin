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

# FIX C — .base over-match: user .base conflict must be left alone; only
# _vaultkeeper-stem .base conflicts are quarantined.
V3="$TMP/vault3"; mkdir -p "$V3"
USER_BASE_CONFLICT="$V3/database.sync-conflict-20260620-120000-ABCDEFG.base"
VK_BASE_CONFLICT="$V3/_vaultkeeper.sync-conflict-20260620-120000-ABCDEFG.base"
printf 'user data\n' > "$USER_BASE_CONFLICT"
printf 'vaultkeeper base\n' > "$VK_BASE_CONFLICT"
OUT3="$(keeper_quarantine_conflicts "$V3")"
# user .base conflict: must be left in place, not quarantined, not in output
[ -e "$USER_BASE_CONFLICT" ] || fail "user .base conflict must remain at original path"
[ "$(find "$V3/.vaultkeeper-quarantine" -name '*database.sync-conflict*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || fail "user .base conflict must NOT be under quarantine"
grep -q "database" <<<"$OUT3" && fail "user .base conflict must NOT appear in QUARANTINE output"
# _vaultkeeper .base conflict: must be quarantined
grep -q "QUARANTINE"$'\t'"_vaultkeeper.sync-conflict" <<<"$OUT3" || fail "_vaultkeeper .base conflict not surfaced"
[ ! -e "$VK_BASE_CONFLICT" ] || fail "_vaultkeeper .base conflict not moved out of vault root"
[ "$(find "$V3/.vaultkeeper-quarantine" -name '*_vaultkeeper.sync-conflict*' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  || fail "_vaultkeeper .base conflict not preserved in quarantine"

# keeper_live_hosts under zsh, against a claim dir holding zero claims. Same
# defect keeper_vault_health carried: an unquoted glob aborts under zsh NOMATCH,
# and `for ... in <glob>` is not exempt. keeper_elect calls this, so an empty
# claim dir takes out election too. These libs are documented bash+zsh clean.
if command -v zsh >/dev/null 2>&1; then
  EMPTY_L="$TMP/zsh-empty-lease"; mkdir -p "$EMPTY_L"
  set +e
  ZLOUT="$(zsh -c ". '$ROOT_DIR/scripts/lib/note-hash.sh'; . '$ROOT_DIR/scripts/lib/keeper-lease.sh'; keeper_live_hosts '$EMPTY_L' 900" 2>"$TMP/zlh.err")"
  ZLRC=$?
  set -e
  [ "$ZLRC" = "0" ] \
    || fail "keeper_live_hosts aborted under zsh on a claim dir with no claims; rc=$ZLRC: $(cat "$TMP/zlh.err")"
  [ -z "$ZLOUT" ] \
    || fail "keeper_live_hosts should list nothing with no claims, printed: $ZLOUT"
  grep -q 'no matches found' "$TMP/zlh.err" \
    && fail "keeper_live_hosts still trips zsh NOMATCH on the claim glob"
fi

echo "PASS: keeper-lease"
