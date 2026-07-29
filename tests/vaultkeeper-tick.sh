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

# --- a faulted tick must not touch the snapshot or Pending.md (#42, panel) ---
# The first cut of the scan-fault gate sat BELOW surfacing_pending_transition, so a
# faulted tick overwrote the snapshot with the truncated candidate set and the next
# healthy tick re-appended everything the short scan had missed. Measured at 3
# duplicated items over 4 fault/heal cycles — in a file the user hand-edits and
# Syncthing replicates. The digest still runs on a partial set (a permanently
# faulting host surfacing nothing is worse than one surfacing a short list), so it
# has to say so: `scan_status: INCOMPLETE`.
CV="$TMP/cyclevault"; mkdir -p "$CV/Inbox"
for _n in 1 2 3; do printf -- '---\ntags: [x]\n---\nbody has [ask:q%s] here\n' "$_n" > "$CV/note$_n.md"; done
CCFG="$TMP/cycle.local.md"; sed "s|^vault_path: .*|vault_path: $CV|" "$CFG" > "$CCFG"
# A scanner that faults on stderr and emits nothing — the shape every scanner has.
FLIB2="$TMP/cyclelib"; mkdir -p "$FLIB2"; cp "${ROOT_DIR}"/scripts/lib/*.sh "$FLIB2/"
cat >> "$FLIB2/vault-scan.sh" <<'EOF'
scan_open_asks() { printf 'vault-scan.sh: CYCLE-FAULT\n' >&2; return 0; }
EOF
FS2="$TMP/cyclescripts"; mkdir -p "$FS2"; cp "${ROOT_DIR}"/scripts/*.sh "$FS2/" 2>/dev/null || true
cp -R "$FLIB2" "$FS2/lib"
HEALTHY="$TMP/healthyscripts"; mkdir -p "$HEALTHY"; cp "${ROOT_DIR}"/scripts/*.sh "$HEALTHY/" 2>/dev/null || true
cp -R "${ROOT_DIR}/scripts/lib" "$HEALTHY/lib"
run_cycle() { OBSIDIAN_LOCAL_MD="$CCFG" VAULTKEEPER_HOST="ml-1" bash "$1/vaultkeeper-tick.sh" >"$TMP/cyc.out" 2>&1 || fail "tick aborted: $(cat "$TMP/cyc.out")"; }
for _c in 1 2 3 4; do
  run_cycle "$HEALTHY"
  run_cycle "$FS2"
done
[ -f "$CV/Librarian.md" ] \
  || fail "faulted tick left no Librarian.md — a degraded host must still surface something"
grep -q 'scan_status: INCOMPLETE' "$CV/Librarian.md" \
  || fail "digest written from a faulted scan does not say so: $(head -5 "$CV/Librarian.md")"
if [ -f "$CV/Pending.md" ]; then
  _dups="$(grep '^- \[ \]' "$CV/Pending.md" | sort | uniq -d | wc -l | tr -d ' ')"
  [ "$_dups" = "0" ] \
    || fail "fault/heal cycles duplicated $_dups Pending.md item(s): $(grep '^- \[ \]' "$CV/Pending.md" | sort | uniq -d | head -3)"
fi

# --- a gate that cannot arm must not wave the tick through (#42, panel) ---
# `SCAN_ERR="$(mktemp …)" || SCAN_ERR=""` failed open: with no buffer the fault
# check could never fire, so the tick recorded a partial scan as complete — the
# exact behavior this gate exists to remove. And mktemp is among the first things
# to fail under the fd/disk exhaustion the gate is watching for, so the guard went
# missing precisely when it was needed.
MV="$TMP/mktempvault"; mkdir -p "$MV/Inbox"
printf -- '---\ntags: [x]\n---\nbody\n' > "$MV/n.md"
MCFG="$TMP/mktemp.local.md"; sed "s|^vault_path: .*|vault_path: $MV|" "$CFG" > "$MCFG"
mkdir -p "$TMP/mbin"
cat > "$TMP/mbin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$*" in *kbscan*) exit 1 ;; esac
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$TMP/mbin/mktemp"
MOUT="$TMP/mktemp.out"
PATH="$TMP/mbin:$PATH" OBSIDIAN_LOCAL_MD="$MCFG" VAULTKEEPER_HOST="ml-1" \
  bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh" >"$MOUT" 2>&1 \
  || fail "a failed mktemp must not abort the tick; got: $(cat "$MOUT")"
grep -q 'scan INCOMPLETE' "$MOUT" \
  || fail "gate could not arm and the tick did not say so; got: $(cat "$MOUT")"
grep -q 'scan complete' "$MOUT" \
  && fail "a tick with no fault buffer reported itself complete: $(cat "$MOUT")"
[ -f "$(keeper_last_scan_file "$MV")" ] \
  && fail "a tick with no fault buffer recorded last_scan"

echo "PASS: vaultkeeper-tick"
