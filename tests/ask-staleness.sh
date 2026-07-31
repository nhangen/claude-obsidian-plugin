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

echo "PASS: ask-staleness"
