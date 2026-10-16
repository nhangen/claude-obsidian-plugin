#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
. "${ROOT_DIR}/scripts/lib/surfacing.sh"
_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/surfacing-XXXXXX")"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
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
chmod 644 "$V/Librarian.md"
printf '%s\n' "$C1" | surfacing_digest "$V"
[ "$(_mode "$V/Librarian.md")" = "644" ] || fail "digest regeneration changed Librarian.md mode to $(_mode "$V/Librarian.md")"

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

# A genuinely different candidate still gets its own line, and the append keeps Pending.md's mode.
chmod 644 "$RV/Pending.md"
t $'UNFILED\tInbox/b.md\n'
[ "$(_mode "$RV/Pending.md")" = "644" ] || fail "Pending.md append changed its mode to $(_mode "$RV/Pending.md")"
grep -qxF -- '- [ ] UNFILED: Inbox/b.md' "$RV/Pending.md" \
  || fail "a new candidate was suppressed by the dedup:"$'\n'"$(cat "$RV/Pending.md")"

# --- Cold-start snapshot write failure must propagate non-zero (#200) ---
CV="$TMP/coldfail"; mkdir -p "$CV"
CCDIR="$(keeper_cache_dir "$CV")"
mkdir -p "$CCDIR"
chmod 500 "$CCDIR"
if [ "$(id -u)" != "0" ]; then
if printf '%s\n' "$C1" | surfacing_pending_transition "$CV" 2>/dev/null; then
  chmod 700 "$CCDIR"
  fail "cold start succeeded despite unwritable snapshot directory"
fi
chmod 700 "$CCDIR"
keeper_has_snapshot "$CV" && fail "failed cold start must not record a snapshot"
fi

# --- Pending transition append failure must propagate and preserve snapshot (#200) ---
AV="$TMP/appendfail"; mkdir -p "$AV"
keeper_state_init "$AV" >/dev/null
printf 'GAP\told.md\n' | surfacing_pending_transition "$AV" \
  || fail "could not seed initial snapshot for append failure test"
keeper_has_snapshot "$AV" || fail "seeded snapshot was not written"

ln -s "/dev/null" "$AV/Pending.md"

# When called in a conditional context (if/||), errexit is suppressed.
# The transition failure must propagate and not advance the snapshot.
if printf 'GAP\told.md\nGAP\tnew.md\n' | surfacing_pending_transition "$AV" 2>/dev/null; then
  fail "transition reported success despite symlinked Pending.md in conditional context"
fi

SNAP_DURING="$(keeper_read_snapshot "$AV")"
grep -q 'new.md' <<<"$SNAP_DURING" \
  && fail "snapshot advanced despite append failure:"$'\n'"$SNAP_DURING"

rm -f "$AV/Pending.md"
printf 'GAP\told.md\nGAP\tnew.md\n' | surfacing_pending_transition "$AV" \
  || fail "retry after clearing append failure returned non-zero"

[ -f "$AV/Pending.md" ] || fail "retry did not create Pending.md"
grep -qxF -- '- [ ] GAP: new.md' "$AV/Pending.md" \
  || fail "retry candidate was lost:"$'\n'"$(cat "$AV/Pending.md")"
grep -q 'old.md' "$AV/Pending.md" \
  && fail "old seed row was re-appended beside retry row:"$'\n'"$(cat "$AV/Pending.md")"

SNAP_AFTER="$(keeper_read_snapshot "$AV")"
grep -q 'new.md' <<<"$SNAP_AFTER" \
  || fail "snapshot was not updated on successful retry:"$'\n'"$SNAP_AFTER"

# --- Existing snapshot read failure must abort before append or advance ---
RVF="$TMP/readfail"; mkdir -p "$RVF"
keeper_state_init "$RVF" >/dev/null
printf 'GAP\told.md\n' | surfacing_pending_transition "$RVF" \
  || fail "could not seed initial snapshot for read failure test"
SNAP_FILE="$(keeper_snapshot_file "$RVF")"
REAL_CAT="$(command -v cat)"
CAT_BIN="$TMP/cat-bin"; mkdir -p "$CAT_BIN"
cat > "$CAT_BIN/cat" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "$FAIL_CAT_PATH" ]; then
  exit 1
fi
exec "$REAL_CAT" "$@"
EOF
chmod +x "$CAT_BIN/cat"
set +e
READ_ERR="$(
  ( export PATH="$CAT_BIN:$PATH" FAIL_CAT_PATH="$SNAP_FILE" REAL_CAT
    printf 'GAP\told.md\nGAP\tnew.md\n' | surfacing_pending_transition "$RVF"
  ) 2>&1
)"
READ_RC=$?
set -e
[ "$READ_RC" -ne 0 ] \
  || fail "transition reported success despite an unreadable existing snapshot"
grep -q 'cannot read' <<<"$READ_ERR" \
  || fail "the snapshot read failure was not observable; got: ${READ_ERR:-<empty>}"
[ ! -f "$RVF/Pending.md" ] \
  || fail "an unreadable snapshot treated every candidate as new: $(cat "$RVF/Pending.md")"
[ "$(keeper_read_snapshot "$RVF")" = $'GAP\told.md' ] \
  || fail "the unreadable snapshot path advanced or replaced the prior snapshot"

# --- Final snapshot write failure after a successful append must propagate (#200) ---
if [ "$(id -u)" != "0" ]; then
  SV="$TMP/snapfail"; mkdir -p "$SV"
  keeper_state_init "$SV" >/dev/null
  printf 'GAP\told.md\n' | surfacing_pending_transition "$SV" \
    || fail "could not seed initial snapshot for snapshot failure test"
  SCDIR="$(keeper_cache_dir "$SV")"
  chmod 500 "$SCDIR"
  if printf 'GAP\told.md\nGAP\tnew.md\n' | surfacing_pending_transition "$SV" 2>/dev/null; then
    chmod 700 "$SCDIR"
    fail "transition reported success despite unwritable snapshot directory in conditional context"
  fi
  chmod 700 "$SCDIR"
  grep -qxF -- '- [ ] GAP: new.md' "$SV/Pending.md" \
    || fail "append before the failed snapshot write was lost"
fi

echo "PASS: surfacing"
