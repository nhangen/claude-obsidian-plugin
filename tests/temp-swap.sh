#!/usr/bin/env bash
# The render-to-temp-then-swap invariant (#43): when the swap fails, the staged temp
# is discarded and the caller hears about it. One of these sites stages into the vault
# root, so a leak is visible in Obsidian and Syncthing replicates it to every host.
#
# Each arm makes the *swap* fail while mktemp still succeeds — the target is a
# directory the process cannot write into, so `mv file dir/file` is refused — because a
# failed mktemp returns before there is anything to leak, which is a different (already
# handled) path. Note a *writable* directory is no good: `mv f d` succeeds by moving f
# into d.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
. "${ROOT_DIR}/scripts/lib/base-views.sh"
. "${ROOT_DIR}/scripts/lib/surfacing.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/temp-swap-XXXXXX")"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
V="$TMP/vault"; mkdir -p "$V/.obsidian"

leaked() { find "$1" -maxdepth 1 -name "$2" 2>/dev/null | head -5; }

# 1. surfacing_digest stages into the VAULT ROOT, so its leak is the one users see.
mkdir -p "$V/Librarian.md"; chmod 500 "$V/Librarian.md"
if printf 'GAP\ta.md\ttype\n' | surfacing_digest "$V" 2>/dev/null; then
  fail "surfacing_digest reported success though the swap could not happen"
fi
L="$(leaked "$V" '.Librarian-*')"
[ -z "$L" ] || fail "a failed digest swap left a temp file in the vault root, which Syncthing replicates:"$'\n'"$L"
chmod 755 "$V/Librarian.md"; rmdir "$V/Librarian.md"

# 2. base_view_write.
mkdir -p "$V/_vaultkeeper.base"; chmod 500 "$V/_vaultkeeper.base"
if base_view_write "$V" "$V/_vaultkeeper.base" 2>/dev/null; then
  fail "base_view_write reported success though the swap could not happen"
fi
B="$(leaked "$V" '.base-*')"
[ -z "$B" ] || fail "a failed base-view swap left a temp file behind:"$'\n'"$B"
chmod 755 "$V/_vaultkeeper.base"; rmdir "$V/_vaultkeeper.base"

# 3. keeper_write_snapshot — the consequential one, and the only site whose temp is
#    staged in TMPDIR while the swap targets somewhere else. Uses the issue's own
#    repro: the snapshot cache dir read-only, so mktemp succeeds and the mv is refused.
export XDG_CACHE_HOME="$TMP/cache"
keeper_state_init "$V" >/dev/null
CDIR="$(keeper_cache_dir "$V")"
chmod 500 "$CDIR"
BEFORE="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'snap-*' 2>/dev/null | wc -l | tr -d ' ')"
if printf 'UNFILED\tInbox/a.md\n' | keeper_write_snapshot "$V" 2>/dev/null; then
  chmod 700 "$CDIR"
  fail "keeper_write_snapshot reported success though the swap could not happen"
fi
AFTER="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'snap-*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$AFTER" -gt "$BEFORE" ]; then
  chmod 700 "$CDIR"
  fail "a failed snapshot swap leaked a temp into TMPDIR (before=$BEFORE after=$AFTER)"
fi
chmod 700 "$CDIR"

# 4. A stuck snapshot must not grow Pending.md. surfacing_pending_transition appends
#    before it writes the snapshot — deliberately, since a failure then costs a
#    duplicated line rather than a lost one — so with the gate stuck every later tick
#    re-sees the same rows as new. With a plain `>>` that was two lines a tick, forever,
#    in a file the user hand-edits and Syncthing replicates.
printf 'GAP\tseed.md\ttype\n' | keeper_write_snapshot "$V" \
  || fail "could not seed a snapshot to make the gate stuck"
keeper_has_snapshot "$V" || fail "the seeded snapshot is not there; arm 4 would test the cold-start path"
chmod 500 "$CDIR"
for _i in 1 2 3 4; do
  printf 'UNFILED\tInbox/a.md\nGAP\tb.md\ttype\n' | surfacing_pending_transition "$V" 2>/dev/null || true
done
chmod 700 "$CDIR"
[ -f "$V/Pending.md" ] || fail "the transition appended nothing at all with a stuck snapshot"
grep -q 'UNFILED: Inbox/a.md' "$V/Pending.md" \
  || fail "the new row never reached Pending.md:"$'\n'"$(cat "$V/Pending.md")"
DUPS="$(grep '^- \[ \]' "$V/Pending.md" | sort | uniq -d | wc -l | tr -d ' ')"
[ "$DUPS" = "0" ] \
  || fail "a stuck snapshot duplicated $DUPS Pending.md line(s) over four ticks:"$'\n'"$(cat "$V/Pending.md")"

# 5. keeper_swap_or_clean mode enforcement: existing target preserves mode, absent target
#    applies 0666 & ~umask (not mktemp's 0600), and stat/chmod failures discard temp.
PM="$TMP/pm"; mkdir -p "$PM"
# 640 under umask 022: the new-file default would be 644, so only preservation yields 640.
(
  umask 022
  printf 'live\n' > "$PM/live.md"; chmod 640 "$PM/live.md"
  PT="$(mktemp "$PM/.t-XXXXXX")"
  keeper_swap_or_clean "$PT" "$PM/live.md" || fail "keeper_swap_or_clean failed on a readable target"
  [ "$(stat -c %a "$PM/live.md" 2>/dev/null || stat -L -f %Lp "$PM/live.md")" = "640" ] || fail "target did not preserve 640 mode"
)

# A symlinked target takes its referent's mode, not the link's own (0777 under GNU stat
# on Linux, 0755 under BSD stat), which would leave the note world-writable.
printf 'real\n' > "$PM/real.md"; chmod 640 "$PM/real.md"; ln -s real.md "$PM/link.md"
PT6="$(mktemp "$PM/.t-XXXXXX")"
keeper_swap_or_clean "$PT6" "$PM/link.md" || fail "keeper_swap_or_clean failed on a symlinked target"
[ "$(stat -L -c %a "$PM/link.md" 2>/dev/null || stat -L -f %Lp "$PM/link.md")" = "640" ] || fail "symlinked target took the link's mode, not its referent's 640"

# Absent target takes 0666 & ~umask, not mktemp's 0600
EXP_MODE="$(printf '%o' "$(( 8#666 & ~ 8#$(umask) ))")"
PT2="$(mktemp "$PM/.t-XXXXXX")"
keeper_swap_or_clean "$PT2" "$PM/absent.md" || fail "keeper_swap_or_clean failed for new target"
[ "$(stat -c %a "$PM/absent.md" 2>/dev/null || stat -L -f %Lp "$PM/absent.md")" = "$EXP_MODE" ] || fail "new target did not get umask default $EXP_MODE"

# Target stat failure aborts swap, removes temp, and logs error
PT3="$(mktemp "$PM/.t-XXXXXX")"
stat() { return 1; }
if PM_ERR="$(keeper_swap_or_clean "$PT3" "$PM/live.md" 2>&1)"; then unset -f stat; fail "swap should fail when stat cannot read mode"; fi
unset -f stat
grep -qF "could not read mode" <<<"$PM_ERR" || fail "stat failure was silent; got: $PM_ERR"
[ ! -e "$PT3" ] || fail "staged temp was not discarded on stat failure"

# Chmod failure aborts swap, removes temp, and logs error
PT4="$(mktemp "$PM/.t-XXXXXX")"
chmod() { return 1; }
if CHMOD_ERR="$(keeper_swap_or_clean "$PT4" "$PM/live.md" 2>&1)"; then unset -f chmod; fail "swap should fail when chmod fails"; fi
unset -f chmod
grep -qF "could not apply mode" <<<"$CHMOD_ERR" || fail "chmod failure was silent; got: $CHMOD_ERR"
[ ! -e "$PT4" ] || fail "staged temp was not discarded on chmod failure"

# Directory target aborts swap, removes temp, and does not move temp into directory
mkdir -p "$PM/dir_target"
PT5="$(mktemp "$PM/.t-XXXXXX")"
if DIR_ERR="$(keeper_swap_or_clean "$PT5" "$PM/dir_target" 2>&1)"; then fail "swap should fail when target is directory"; fi
grep -qF "target is a directory" <<<"$DIR_ERR" || fail "directory error not reported; got: $DIR_ERR"
[ ! -e "$PT5" ] || fail "staged temp was not discarded on directory target"
[ ! -e "$PM/dir_target/$(basename "$PT5")" ] || fail "temp leaked into directory target"

echo "PASS: temp-swap"
