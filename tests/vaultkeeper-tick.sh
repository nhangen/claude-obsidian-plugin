#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vk-tick-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
V="$TMP/vault"; mkdir -p "$V/Inbox"
printf -- '---\ntags: [x]\n---\n\nbody\n' > "$V/gap.md"   # missing type
printf 'loose\n' > "$V/Inbox/u.md"

CFG="$TMP/obsidian.local.md"
cat > "$CFG" <<EOF
---
vault_path: $V
frontmatter_required: tags type
keeper_host_priority: ml-1 mbp
keeper_interval_secs: 900
---
EOF
export OBSIDIAN_LOCAL_MD="$CFG"

run_tick() { VAULTKEEPER_HOST="$1" bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh"; }

# Owner run (this host = ml-1, top priority): full substrate runs.
run_tick "ml-1"
[ -f "$V/Librarian.md" ] || fail "owner tick did not write Librarian.md"
grep -q 'gap.md' "$V/Librarian.md" || fail "frontmatter gap not surfaced"
[ -f "$V/_vaultkeeper.base" ] || fail "owner tick did not write .base"
# state lives in cache, NOT in the vault
[ -d "$(keeper_cache_dir "$V")" ] || fail "cache dir missing"
find "$V" -name 'candidates.snapshot' | grep -q . && fail "snapshot leaked into vault"
# cold start: nothing appended to Pending yet
[ ! -f "$V/Pending.md" ] || [ "$(grep -c '^- \[ \]' "$V/Pending.md")" -eq 0 ] \
  || fail "cold-start tick must not append to Pending"

# Non-owner run: mbp is NOT owner while ml-1's claim is live -> defers, no writes.
rm -f "$V/Librarian.md"
run_tick "mbp"
[ ! -f "$V/Librarian.md" ] || fail "non-owner must not write Librarian.md"

# --- a scan whose scanners complained is not recorded as complete (#42) ---
# 710 consecutive ticks on the maintainer's host logged `Too many open files`
# from vault-scan.sh and then `scan complete`, so last_scan advanced on a
# truncated candidate set. last_scan drives /obsidian:ask's staleness banner and
# the owner-election window; recording a partial scan tells both the vault was
# fully examined. The fd bug is fixed in vault-scan.sh, but the gate has to exist
# independently — any future scanner fault must reach the same conclusion.
SV="$TMP/faultvault"; mkdir -p "$SV/Inbox"
printf -- '---\ntags: [x]\n---\nbody\n' > "$SV/n.md"
FCFG="$TMP/fault.local.md"
sed "s|^vault_path: .*|vault_path: $SV|" "$CFG" > "$FCFG"
# Shadow one scanner with a version that writes to stderr and still returns 0 —
# exactly the shape every scanner has today.
FLIB="$TMP/faultlib"; mkdir -p "$FLIB"
cp "${ROOT_DIR}"/scripts/lib/*.sh "$FLIB/"
cat >> "$FLIB/vault-scan.sh" <<'EOF'
scan_open_asks() { printf 'vault-scan.sh: SIMULATED-SCANNER-FAULT\n' >&2; return 0; }
EOF
FSCRIPTS="$TMP/faultscripts"; mkdir -p "$FSCRIPTS"
cp "${ROOT_DIR}"/scripts/*.sh "$FSCRIPTS/" 2>/dev/null || true
cp -R "$FLIB" "$FSCRIPTS/lib"
FOUT="$TMP/fault.out"
OBSIDIAN_LOCAL_MD="$FCFG" VAULTKEEPER_HOST="ml-1" \
  bash "$FSCRIPTS/vaultkeeper-tick.sh" >"$FOUT" 2>&1 \
  || fail "a scanner fault must not abort the tick; got: $(cat "$FOUT")"
grep -q 'SIMULATED-SCANNER-FAULT' "$FOUT" \
  || fail "the scanner's own words were dropped; got: $(cat "$FOUT")"
grep -q 'scan INCOMPLETE' "$FOUT" \
  || fail "a faulted scan was not named incomplete; got: $(cat "$FOUT")"
grep -q 'scan complete' "$FOUT" \
  && fail "a faulted scan reported itself complete; got: $(cat "$FOUT")"
[ -f "$(keeper_last_scan_file "$SV")" ] \
  && fail "a faulted scan recorded last_scan, so the staleness banner will lie"

echo "PASS: vaultkeeper-tick"
