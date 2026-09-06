#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
. "${ROOT_DIR}/scripts/lib/keeper-lease.sh"
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

# A deferring host has no local state at all — only the elected owner scans and
# keeper state never syncs — so /obsidian:ask on that host must speak from the
# vault's own evidence: the owner's INCOMPLETE digest, and the lease naming who
# the owner is (#95). This is the entrypoint half; tests/keeper-state.sh covers
# the branches.
D="$TMP/deferring"; mkdir -p "$D"
DCFG="$TMP/deferring.local.md"
printf -- '---\nvault_path: %s\nkeeper_interval_secs: 900\nkeeper_host_priority: ml-1 mbp\n---\n' \
  "$D" > "$DCFG"
drun() { OBSIDIAN_LOCAL_MD="$DCFG" bash "${ROOT_DIR}/scripts/ask-staleness.sh"; }

[ -z "$(drun)" ] || fail "warned about a vault the keeper has never run on: $(drun)"
keeper_claim_write "$D/.vaultkeeper" "ml-1"
printf '# Librarian\n\nlast_scan: %s\nscan_status: INCOMPLETE\n' "$(now_epoch)" > "$D/Librarian.md"
case "$(drun)" in
  *faulted*ml-1*) : ;;
  *) fail "the owner's faulting scans stayed invisible through the entrypoint: $(drun)" ;;
esac
printf '# Librarian\n\nlast_scan: %s\n' "$(now_epoch)" > "$D/Librarian.md"
[ -z "$(drun)" ] || fail "warned on a vault the owner is scanning fine: $(drun)"

# The optional config keys are exactly that. /obsidian:setup's template does not
# write keeper_interval_secs, and an unmatched grep is a failed pipeline under
# this script's pipefail — so on a default install the check aborted before the
# banner ever ran, printing nothing, which every consumer reads as healthy.
MIN="$TMP/minimal.local.md"
printf -- '---\nvault_path: %s\n---\n' "$D" > "$MIN"
MINOUT="$(OBSIDIAN_LOCAL_MD="$MIN" bash "${ROOT_DIR}/scripts/ask-staleness.sh")" \
  || fail "a config with only vault_path aborted the freshness check"
printf '# Librarian\n\nlast_scan: %s\nscan_status: INCOMPLETE\n' "$(now_epoch)" > "$D/Librarian.md"
case "$(OBSIDIAN_LOCAL_MD="$MIN" bash "${ROOT_DIR}/scripts/ask-staleness.sh")" in
  *faulted*) : ;;
  *) fail "a faulting scan stayed silent on a config without the optional keys" ;;
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
