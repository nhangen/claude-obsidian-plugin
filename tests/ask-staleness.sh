#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ask-stale-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
V="$TMP/vault"; mkdir -p "$V"; keeper_state_init "$V" >/dev/null
CFG="$TMP/obsidian.local.md"
printf -- '---\nvault_path: %s\nkeeper_interval_secs: 900\n---\n' "$V" > "$CFG"
export OBSIDIAN_LOCAL_MD="$CFG"

run() { bash "${ROOT_DIR}/scripts/ask-staleness.sh"; }

# fresh: no banner
keeper_record_scan "$V"
[ -z "$(run)" ] || fail "fresh index should not warn"
# stale: banner
printf '1000\n' > "$(keeper_cache_dir "$V")/last_scan"
[ -n "$(run)" ] || fail "stale index should warn"

# never-completed, through the real script. tests/keeper-state.sh covers the branch at
# the library level; this is the only test that runs what /obsidian:ask actually
# invokes — config resolution, interval default and all — so the state #52 exists to
# surface should be visible from here, and the cache-dir-only case should not be.
rm -f "$(keeper_last_scan_file "$V")"
[ -z "$(run)" ] || fail "a cache dir with no attempt must not warn through the real entrypoint"
keeper_record_attempt "$V"
case "$(run)" in
  *"never completed"*) : ;;
  *) fail "entrypoint did not surface the never-completed state: $(run)" ;;
esac

# A degraded state file must reach the user through the real entrypoint too. An
# empty last_scan (what ENOSPC leaves: `>` truncates on open, then fails on
# write) used to read as "never scanned" here, and an empty last_attempt as
# "nothing has tried" — silence, which every consumer treats as healthy (#94).
: > "$(keeper_last_scan_file "$V")"
case "$(run)" in
  *unreadable*) : ;;
  *) fail "an empty last_scan did not surface through the entrypoint: $(run)" ;;
esac
rm -f "$(keeper_last_scan_file "$V")"
: > "$(keeper_last_attempt_file "$V")"
case "$(run)" in
  *unreadable*) : ;;
  *) fail "an empty last_attempt did not surface through the entrypoint: $(run)" ;;
esac

# The entrypoint must not let its own failure pass as a clean bill of health:
# it runs under set -e with staleness_banner as its last command, so an abort
# there exits 1 with no stdout — and stdout is the only channel the consumers
# read ("if it prints a line, show it"). Pinned by inspection because nothing
# reachable through this script can make the banner abort any more; that is the
# property, and the guard is what preserves it.
grep -q 'staleness_banner .*||' "${ROOT_DIR}/scripts/ask-staleness.sh" \
  || fail "ask-staleness.sh no longer guards the banner call; a failed check would print nothing"

echo "PASS: ask-staleness"
