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
if base_view_write "$V/_vaultkeeper.base" 2>/dev/null; then
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

echo "PASS: temp-swap"
