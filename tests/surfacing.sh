#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
. "${ROOT_DIR}/scripts/lib/surfacing.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/surfacing-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
V="$TMP/vault"; mkdir -p "$V"; keeper_state_init "$V" >/dev/null

C1=$'GAP\tProjects/gap.md\ttype\nUNFILED\tInbox/x.md'

# --- Librarian.md: atomic, machine-owned, regenerated ---
printf '%s\n' "$C1" | surfacing_digest "$V"
[ -f "$V/Librarian.md" ] || fail "Librarian.md not written"
grep -q 'MACHINE-OWNED' "$V/Librarian.md" || fail "missing machine-owned header"
grep -q 'Projects/gap.md' "$V/Librarian.md" || fail "gap not in digest"
# hand-added line must NOT survive the next scan (full overwrite)
printf '\nHAND EDIT\n' >> "$V/Librarian.md"
printf '%s\n' "$C1" | surfacing_digest "$V"
grep -q 'HAND EDIT' "$V/Librarian.md" && fail "hand edit survived (not machine-owned)"

# --- Pending.md transition gating ---
# scan 1 = cold cache: snapshot written, Pending untouched
printf '%s\n' "$C1" | surfacing_pending_transition "$V"
[ ! -f "$V/Pending.md" ] || [ "$(grep -c '^- \[ \]' "$V/Pending.md")" -eq 0 ] \
  || fail "cold start must not append to Pending"
keeper_has_snapshot "$V" || fail "cold start must write snapshot"

# scan 2 = identical candidates: nothing new appends
printf '%s\n' "$C1" | surfacing_pending_transition "$V"
[ ! -f "$V/Pending.md" ] || [ "$(grep -c '^- \[ \]' "$V/Pending.md")" -eq 0 ] \
  || fail "unchanged scan must append nothing"

# scan 3 = one NEW candidate: exactly one line appends
C2=$'GAP\tProjects/gap.md\ttype\nUNFILED\tInbox/x.md\nASK\tProjects/new.md'
printf '%s\n' "$C2" | surfacing_pending_transition "$V"
[ "$(grep -c '^- \[ \]' "$V/Pending.md")" -eq 1 ] || fail "exactly one new item expected"
grep -q 'Projects/new.md' "$V/Pending.md" || fail "new ASK item not appended"

# --- a returning candidate must not land next to a ticked line (#37) ----------
# The transition diffs only against the persisted snapshot, and that snapshot is
# overwritten unconditionally. So a candidate that drops out of one scan and returns
# in a later one got a fresh `- [ ]` appended right beside the `- [x]` the user had
# already ticked. Pending.md is hand-edited, which makes this the one path where a bug
# touches notes somebody is working in.
RV="$TMP/returnvault"; mkdir -p "$RV/.obsidian"
export XDG_CACHE_HOME="$TMP/rcache"
keeper_state_init "$RV" >/dev/null

t() { printf '%s' "$1" | surfacing_pending_transition "$RV"; }

t $'UNFILED\tInbox/a.md\n'          # first call only seeds the snapshot
t ''                                 # a drops out
t $'UNFILED\tInbox/a.md\n'         # …and returns: appended once, correctly
grep -qxF -- '- [ ] UNFILED: Inbox/a.md' "$RV/Pending.md" \
  || fail "the returning candidate was never appended: $(cat "$RV/Pending.md" 2>/dev/null)"

# The user ticks it.
sed 's/^- \[ \] UNFILED/- [x] UNFILED/' "$RV/Pending.md" > "$RV/Pending.tmp" && mv "$RV/Pending.tmp" "$RV/Pending.md"
grep -qxF -- '- [x] UNFILED: Inbox/a.md' "$RV/Pending.md" || fail "the fixture did not tick the line"

t ''                                 # drops out again
t $'UNFILED\tInbox/a.md\n'         # and returns again
COUNT="$(grep -c 'UNFILED: Inbox/a.md' "$RV/Pending.md" | tr -d ' ')"
[ "$COUNT" = "1" ] \
  || fail "a returning candidate was appended beside the line the user had already ticked ($COUNT lines):"$'\n'"$(cat "$RV/Pending.md")"
grep -qxF -- '- [x] UNFILED: Inbox/a.md' "$RV/Pending.md" \
  || fail "the user's tick was lost:"$'\n'"$(cat "$RV/Pending.md")"

# A genuinely different candidate still gets its own line.
t $'UNFILED\tInbox/b.md\n'
grep -qxF -- '- [ ] UNFILED: Inbox/b.md' "$RV/Pending.md" \
  || fail "a new candidate was suppressed by the dedup:"$'\n'"$(cat "$RV/Pending.md")"

echo "PASS: surfacing"
