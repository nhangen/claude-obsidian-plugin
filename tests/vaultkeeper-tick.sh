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

# ...and it must not claim a scan ATTEMPT either. The attempt is what staleness_banner
# reads to decide whether an absent last_scan is a fault, so a deferring host that
# records one warns on every ask, forever, about a vault the elected owner is scanning
# fine — the false alarm that keying off the cache dir produced. Needs its own vault:
# $V already carries ml-1's last_scan, so the banner there takes the aging branch and
# never reaches the never-completed one.
NV="$TMP/nonownervault"; mkdir -p "$NV/Inbox"
printf -- '---\ntags: [x]\ntype: note\n---\nbody\n' > "$NV/n.md"
NCFG="$TMP/nonowner.local.md"
sed "s|^vault_path: .*|vault_path: $NV|" "$CFG" > "$NCFG"
OBSIDIAN_LOCAL_MD="$NCFG" run_tick "ml-1" >/dev/null    # ml-1 takes the lease
rm -f "$(keeper_last_scan_file "$NV")" "$(keeper_last_attempt_file "$NV")"
OBSIDIAN_LOCAL_MD="$NCFG" run_tick "mbp" >/dev/null     # mbp defers, scans nothing
[ -d "$(keeper_cache_dir "$NV")" ] \
  || fail "fixture precondition: the deferring tick should still have created the cache dir"
[ ! -f "$(keeper_last_attempt_file "$NV")" ] \
  || fail "a deferring host claimed an attempt it never made — the banner will cry wolf forever"
[ -z "$(staleness_banner "$NV" 900)" ] \
  || fail "deferring host must stay silent, got: $(staleness_banner "$NV" 900)"

# --- a scan whose scanners complained is not recorded as complete (#42) ---
# 700+ consecutive ticks on the maintainer's host logged `Too many open files`
# from vault-scan.sh and then `scan complete`, so last_scan advanced on a
# truncated candidate set. last_scan's only consumer is /obsidian:ask's staleness
# banner (via scripts/ask-staleness.sh) — NOT owner election, which reads
# claim-file mtimes and never looks at last_scan. The fd bug is fixed in
# vault-scan.sh, but the gate has to exist independently — any future scanner
# fault must reach the same conclusion.
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
# ...and withholding it has to reach the consumer. This host faults on its very first
# tick, so it has no previous last_scan to age out; before the attempt file existed the
# banner had nothing to distinguish it from a fresh install and stayed silent. The gate
# was honest and no reader could hear it.
[ -f "$(keeper_last_attempt_file "$SV")" ] \
  || fail "a faulted tick recorded no attempt, so the banner cannot tell it from a fresh install"
FBANNER="$(staleness_banner "$SV" 900)"
[ -n "$FBANNER" ] || fail "a host whose only scans faulted still looks healthy to the banner"
case "$FBANNER" in
  *"never completed"*) : ;;
  *) fail "banner did not name the real state: $FBANNER" ;;
esac

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

# --- a faulted tick keeps the quarantine receipt (#58) -----------------------
# The four scanners re-derive their rows every tick, so withholding them on a fault
# costs nothing. QUARANTINE is a receipt for an irreversible `mv`, emitted once, and
# the file it names is excluded from every later walk — so a row withheld here was
# withheld permanently and the user never learned a sync conflict needed merging.
RQV="$TMP/receiptvault"; mkdir -p "$RQV/Inbox"
printf -- '---\ntags: [x]\ntype: a\n---\nbody\n' > "$RQV/n.md"
printf 'conflicted\n' > "$RQV/Pending.sync-conflict-20260730-120000-RECEIPT.md"
# A re-derivable row that is NEW on the faulted tick. It must NOT be appended: the
# exception is for rows that cannot come back, and letting the rest through reopens
# #49's duplication — the snapshot is deliberately not updated, so the next healthy
# tick's transition would append the same row a second time.
printf -- '---\ntags: [x]\n---\nbody\n' > "$RQV/rederivable-gap.md"
RQCFG="$TMP/receipt.local.md"; sed "s|^vault_path: .*|vault_path: $RQV|" "$CFG" > "$RQCFG"
# A scanner that faults, so the tick takes the gated path with a real conflict present.
RQLIB="$TMP/receiptlib"; mkdir -p "$RQLIB"; cp "${ROOT_DIR}"/scripts/lib/*.sh "$RQLIB/"
cat >> "$RQLIB/vault-scan.sh" <<'EOF'
scan_open_asks() { printf 'vault-scan.sh: RECEIPT-FAULT\n' >&2; return 0; }
EOF
RQS="$TMP/receiptscripts"; mkdir -p "$RQS"; cp "${ROOT_DIR}"/scripts/*.sh "$RQS/" 2>/dev/null || true
cp -R "$RQLIB" "$RQS/lib"
RQOUT="$TMP/receipt.out"
OBSIDIAN_LOCAL_MD="$RQCFG" VAULTKEEPER_HOST="ml-1" \
  bash "$RQS/vaultkeeper-tick.sh" >"$RQOUT" 2>&1 \
  || fail "the faulted receipt tick aborted; got: $(cat "$RQOUT")"
grep -q 'scan INCOMPLETE' "$RQOUT" \
  || fail "the receipt fixture did not fault, so it proves nothing; got: $(cat "$RQOUT")"
[ -f "$RQV/Pending.md" ] \
  || fail "a faulted tick dropped the quarantine receipt entirely — no later tick can re-emit it"
grep -q 'QUARANTINE: Pending.sync-conflict-20260730-120000-RECEIPT.md' "$RQV/Pending.md" \
  || fail "Pending.md has no QUARANTINE line for the moved conflict: $(cat "$RQV/Pending.md")"
# The snapshot must still be untouched — that is what stops a truncated candidate set
# from making the next healthy tick re-append everything this scan missed.
keeper_has_snapshot "$RQV" \
  && fail "the faulted tick wrote the prior-scan snapshot; the transition gate is defeated"
grep -q 'GAP: rederivable-gap.md' "$RQV/Pending.md" \
  && fail "the faulted tick appended a re-derivable row too; the snapshot is not updated, so the next healthy tick will append it again: $(cat "$RQV/Pending.md")"
# And the row must not duplicate: a healthy tick afterwards no longer sees the file
# (it is inside .vaultkeeper-quarantine), so `comm -23` must not re-add it.
OBSIDIAN_LOCAL_MD="$RQCFG" VAULTKEEPER_HOST="ml-1" \
  bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh" >>"$RQOUT" 2>&1 \
  || fail "the follow-up healthy tick aborted; got: $(cat "$RQOUT")"
_rq="$(grep -c 'QUARANTINE: Pending.sync-conflict-20260730-120000-RECEIPT.md' "$RQV/Pending.md" | tr -d ' ')"
[ "$_rq" = "1" ] \
  || fail "the quarantine receipt appears $_rq times in Pending.md after a fault/heal cycle"

# --- the whole tick under real fd exhaustion (#57) ---------------------------
# The scanner fix and the fault gate were each pinned individually, but nothing ran
# the composition against the condition that produced the incident: the tick's own
# fault arms shadow a scanner with a stub that writes to stderr, and per
# `test-the-fix-not-the-investigation` a stub override exercising the stub is not
# coverage of the shipped condition. This arm exhausts real file descriptors.
#
# The negative half restores the PRE-#49 scan_clusters verbatim from
# f670411^ — nested process substitutions, two live fds per directory. Reconstructed
# rather than stubbed, so what it proves is that the shipped code is what survives.
FDV="$TMP/fdtickvault"; mkdir -p "$FDV/Inbox"
for _i in $(seq 1 120); do
  _d="$FDV/Folder $_i"; mkdir -p "$_d"
  for _j in 1 2 3; do printf -- '---\ntags: [x]\ntype: a\n---\nbody\n' > "$_d/topic$_i note $_j.md"; done
done
FDCFG="$TMP/fdtick.local.md"; sed "s|^vault_path: .*|vault_path: $FDV|" "$CFG" > "$FDCFG"

# 1. Shipped code, 64 fds: the tick completes and records the scan.
FD1="$TMP/fdtick-fixed.out"
( ulimit -n 64; OBSIDIAN_LOCAL_MD="$FDCFG" VAULTKEEPER_HOST="ml-1" \
    bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh" >"$FD1" 2>&1 ) \
  || fail "the tick failed under ulimit -n 64; got: $(cat "$FD1")"
grep -q 'scan complete' "$FD1" \
  || fail "the tick did not complete under ulimit -n 64; got: $(cat "$FD1")"
grep -q 'scan INCOMPLETE' "$FD1" \
  && fail "the tick reported a fault under ulimit -n 64 with the shipped scanner; got: $(cat "$FD1")"
[ -f "$(keeper_last_scan_file "$FDV")" ] \
  || fail "the tick completed under ulimit -n 64 but did not record last_scan"
# 120 dirs x 3 files sharing 2 tokens each — the whole set, not whatever fd headroom
# happened to allow. This is the number the incident's host got wrong (503 idle, 211
# under load, silently).
_fdclusters="$(grep -c '^- ' "$FDV/Librarian.md" || true)"
[ "$_fdclusters" -ge 240 ] \
  || fail "the digest lists only $_fdclusters rows under ulimit -n 64; the candidate set was truncated"

# 2. Pre-#49 scanner, same limit: the tick must NOT record the scan as complete.
FDLIB="$TMP/fdticklib"; mkdir -p "$FDLIB"; cp "${ROOT_DIR}"/scripts/lib/*.sh "$FDLIB/"
git -C "$ROOT_DIR" show f670411^:scripts/lib/vault-scan.sh \
  | sed -n '/^scan_clusters/,/^}/p' >> "$FDLIB/vault-scan.sh" \
  || fail "could not recover the pre-#49 scan_clusters from git history"
FDS="$TMP/fdtickscripts"; mkdir -p "$FDS"; cp "${ROOT_DIR}"/scripts/*.sh "$FDS/" 2>/dev/null || true
cp -R "$FDLIB" "$FDS/lib"
FDV2="$TMP/fdtickvault2"; cp -R "$FDV" "$FDV2"; rm -f "$FDV2/Librarian.md" "$FDV2/Pending.md"
FDCFG2="$TMP/fdtick2.local.md"; sed "s|^vault_path: .*|vault_path: $FDV2|" "$CFG" > "$FDCFG2"
FD2="$TMP/fdtick-old.out"
( ulimit -n 64; OBSIDIAN_LOCAL_MD="$FDCFG2" VAULTKEEPER_HOST="ml-1" \
    bash "$FDS/vaultkeeper-tick.sh" >"$FD2" 2>&1 ) \
  || fail "the reverted-scanner tick aborted rather than reporting; got: $(cat "$FD2")"
grep -q 'scan INCOMPLETE' "$FD2" \
  || fail "the pre-#49 scanner exhausted fds and the tick still called the scan complete — the gate does not see it: $(cat "$FD2")"
[ -f "$(keeper_last_scan_file "$FDV2")" ] \
  && fail "the reverted-scanner tick recorded last_scan on a truncated scan"

# --- a failed quarantine move is a fault too (#53) ---------------------------
# `CONFLICTS="$(keeper_quarantine_conflicts … || true)"` ran above the buffer, so a
# failed `mv` printed `failed to quarantine …` straight past the gate and `|| true`
# threw away the status: the QUARANTINE list came back short and the tick recorded
# the scan as complete. Same invariant as the scanners, one function over.
if [ "$(id -u)" = "0" ]; then
  echo "note: running as root, skipping the failed-quarantine arm" >&2
else
  QV="$TMP/quarantinevault"; mkdir -p "$QV/Inbox"
  printf -- '---\ntags: [x]\n---\nbody\n' > "$QV/n.md"
  # A real Syncthing conflict name, so the quarantine matcher fires on it.
  printf 'conflicted\n' > "$QV/Pending.sync-conflict-20260730-120000-ABCDEFG.md"
  # Pre-create the destination read-only: mkdir -p succeeds, the mv into it does not.
  mkdir -p "$QV/.vaultkeeper-quarantine"
  chmod 555 "$QV/.vaultkeeper-quarantine"
  QCFG="$TMP/quarantine.local.md"; sed "s|^vault_path: .*|vault_path: $QV|" "$CFG" > "$QCFG"
  QOUT="$TMP/quarantine.out"
  OBSIDIAN_LOCAL_MD="$QCFG" VAULTKEEPER_HOST="ml-1" \
    bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh" >"$QOUT" 2>&1 \
    || { chmod 755 "$QV/.vaultkeeper-quarantine"; fail "a failed quarantine must not abort the tick; got: $(cat "$QOUT")"; }
  chmod 755 "$QV/.vaultkeeper-quarantine"
  grep -q 'scan INCOMPLETE' "$QOUT" \
    || fail "a failed quarantine move was recorded as a complete scan; got: $(cat "$QOUT")"
  grep -q 'quarantine' "$QOUT" \
    || fail "the quarantine failure's own words never reached the report; got: $(cat "$QOUT")"
  [ -f "$(keeper_last_scan_file "$QV")" ] \
    && fail "a tick whose quarantine failed still recorded last_scan"

  # And a SUCCESSFUL quarantine must run before the scanners, not merely inside the
  # same capture: run after them, the conflict file is still in place when they walk
  # the vault, so a file that was correctly quarantined also gets reported as a
  # frontmatter gap that no longer exists.
  QV2="$TMP/quarantineok"; mkdir -p "$QV2/Inbox"
  printf -- '---\ntags: [x]\ntype: a\n---\nbody\n' > "$QV2/n.md"
  printf 'conflicted\n' > "$QV2/Pending.sync-conflict-20260730-120000-HIJKLMN.md"
  Q2CFG="$TMP/quarantineok.local.md"; sed "s|^vault_path: .*|vault_path: $QV2|" "$CFG" > "$Q2CFG"
  Q2OUT="$TMP/quarantineok.out"
  OBSIDIAN_LOCAL_MD="$Q2CFG" VAULTKEEPER_HOST="ml-1" \
    bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh" >"$Q2OUT" 2>&1 \
    || fail "a successful quarantine aborted the tick; got: $(cat "$Q2OUT")"
  grep -q 'scan complete' "$Q2OUT" \
    || fail "a successful quarantine was reported as a fault; got: $(cat "$Q2OUT")"
  grep -q '^- Pending.sync-conflict-20260730-120000-HIJKLMN.md$' "$QV2/Librarian.md" \
    || fail "the quarantined conflict was not listed in the digest: $(cat "$QV2/Librarian.md")"
  grep -qE '^- Pending\.sync-conflict-20260730-120000-HIJKLMN\.md\s' "$QV2/Librarian.md" \
    && fail "the quarantined file was ALSO scanned as a gap, so quarantine ran after the scanners: $(cat "$QV2/Librarian.md")"
fi

# --- an unreadable directory must not latch the gate (#51) -------------------
# One `chmod 000` directory made find print `Permission denied`, and the gate — which
# could only see bytes on stderr — reported INCOMPLETE on every tick from then on and
# never recorded last_scan. No tick can fix a permission, so there was no recovery:
# a vault whose every readable note WAS scanned looked permanently broken. Four
# agents reproduced it across consecutive ticks.
if [ "$(id -u)" = "0" ]; then
  echo "note: running as root, skipping the unreadable-directory tick arm" >&2
else
  PTV="$TMP/permtickvault"; mkdir -p "$PTV/Inbox" "$PTV/locked"
  printf -- '---\ntags: [x]\n---\nbody\n' > "$PTV/n.md"
  printf -- '---\ntags: [x]\n---\nbody\n' > "$PTV/locked/hidden.md"
  chmod 000 "$PTV/locked"
  PTCFG="$TMP/permtick.local.md"; sed "s|^vault_path: .*|vault_path: $PTV|" "$CFG" > "$PTCFG"
  PTOUT="$TMP/permtick.out"
  # Twice: the latch only showed up as "and it never recovers", so one tick cannot
  # tell a latch from a first fault.
  for _r in 1 2; do
    OBSIDIAN_LOCAL_MD="$PTCFG" VAULTKEEPER_HOST="ml-1" \
      bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh" >"$PTOUT" 2>&1 \
      || { chmod 755 "$PTV/locked"; fail "an unreadable directory aborted the tick; got: $(cat "$PTOUT")"; }
  done
  if grep -q 'scan INCOMPLETE' "$PTOUT"; then
    chmod 755 "$PTV/locked"
    fail "an unreadable directory still reports INCOMPLETE, so the gate latches with no recovery path; got: $(cat "$PTOUT")"
  fi
  grep -q 'scan complete' "$PTOUT" \
    || { chmod 755 "$PTV/locked"; fail "the scan of every readable note was not reported complete; got: $(cat "$PTOUT")"; }
  [ -f "$(keeper_last_scan_file "$PTV")" ] \
    || { chmod 755 "$PTV/locked"; fail "last_scan was withheld, so the staleness banner will nag forever about a healthy vault"; }
  # Suppressed is not the same as ignored: the condition has to be visible, by count.
  grep -q 'unreadable' "$PTOUT" \
    || { chmod 755 "$PTV/locked"; fail "the unreadable path was never mentioned — that is silence, not classification; got: $(cat "$PTOUT")"; }
  grep -q '^paths_unreadable: 1' "$PTV/Librarian.md" \
    || { chmod 755 "$PTV/locked"; fail "the digest does not record the unreadable count: $(head -6 "$PTV/Librarian.md")"; }
  # …and the count must not carry the absolute host path into the synced digest.
  case "$(cat "$PTV/Librarian.md")" in
    *"$PTV/locked"*) chmod 755 "$PTV/locked"; fail "the digest leaked the unreadable path itself" ;;
  esac
  chmod 755 "$PTV/locked"
fi

# --- one repeated benign error must not crowd out a serious one (#54) --------
# `_scan_find_md` backs three scanners, so a single unreadable directory puts the
# same `find: … Permission denied` line in the buffer three times. The 300-char
# clamp then spent its whole budget on the repetition and cut off mid-word, so the
# fault the user actually needed to see never got reported. The buffer is the only
# description of the fault they get.
RV="$TMP/repeatvault"; mkdir -p "$RV/Inbox"
printf -- '---\ntags: [x]\n---\nbody\n' > "$RV/n.md"
RCFG="$TMP/repeat.local.md"; sed "s|^vault_path: .*|vault_path: $RV|" "$CFG" > "$RCFG"
RLIB="$TMP/repeatlib"; mkdir -p "$RLIB"; cp "${ROOT_DIR}"/scripts/lib/*.sh "$RLIB/"
cat >> "$RLIB/vault-scan.sh" <<'EOF'
scan_open_asks() {
  local i
  # Identical every time, exactly as one chmod 000 directory reaches the buffer
  # through three callers — only more of them, so the clamp is unambiguous.
  for i in $(seq 1 40); do
    printf 'find: /vault/some/deep/unreadable/directory/path: Permission denied\n' >&2
  done
  printf 'find: CRITICAL-LATE-FAULT too many open files\n' >&2
  return 0
}
EOF
RS="$TMP/repeatscripts"; mkdir -p "$RS"; cp "${ROOT_DIR}"/scripts/*.sh "$RS/" 2>/dev/null || true
cp -R "$RLIB" "$RS/lib"
ROUT="$TMP/repeat.out"
OBSIDIAN_LOCAL_MD="$RCFG" VAULTKEEPER_HOST="ml-1" \
  bash "$RS/vaultkeeper-tick.sh" >"$ROUT" 2>&1 \
  || fail "a repeated scanner fault must not abort the tick; got: $(cat "$ROUT")"
grep -q 'scan INCOMPLETE' "$ROUT" \
  || fail "the repeated-fault tick was not named incomplete; got: $(cat "$ROUT")"
grep -q 'CRITICAL-LATE-FAULT' "$ROUT" \
  || fail "the serious fault was truncated away by 40 copies of a benign one; got: $(cat "$ROUT")"
# The tick reports the buffer twice (once raw, once in the INCOMPLETE line), so a
# deduplicated buffer shows the repeated message twice in total. Without the dedup
# the clamp packs several copies into each of those lines.
_reps="$(grep -o 'Permission denied' "$ROUT" | wc -l | tr -d ' ')"
[ "$_reps" -le 2 ] \
  || fail "the repeated message appears $_reps times, so it is still eating the 300-char budget"

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

# --- an unwritable cache dir degrades the tick, it does not abort it ---
# keeper_record_attempt is the first write after the ownership gate, so calling it
# unchecked under `set -e` would kill the run there — above the scan, the base view AND
# the digest — and a host with a full or unwritable cache dir would lose the
# Librarian.md it can still produce. ENOSPC is the same correlated failure class as the
# mktemp case above, so it takes the same route: fold into SCAN_FAULT, say so, keep the
# digest, withhold last_scan.
UV="$TMP/unwritablevault"; mkdir -p "$UV/Inbox"
printf -- '---\ntags: [x]\n---\nbody\n' > "$UV/n.md"
UCFG="$TMP/unwritable.local.md"; sed "s|^vault_path: .*|vault_path: $UV|" "$CFG" > "$UCFG"
UCACHE="$(keeper_cache_dir "$UV")"; mkdir -p "$UCACHE"; chmod 555 "$UCACHE"
UOUT="$TMP/unwritable.out"
set +e
OBSIDIAN_LOCAL_MD="$UCFG" VAULTKEEPER_HOST="ml-1" \
  bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh" >"$UOUT" 2>&1
URC=$?
set -e
chmod 755 "$UCACHE"
[ "$URC" -eq 0 ] || fail "an unwritable cache dir aborted the tick (rc=$URC); got: $(cat "$UOUT")"
[ -f "$UV/Librarian.md" ] \
  || fail "the digest was lost when the cache dir was unwritable; got: $(cat "$UOUT")"
grep -q 'scan INCOMPLETE' "$UOUT" \
  || fail "an unaccountable scan did not name itself incomplete; got: $(cat "$UOUT")"
grep -q 'scan complete' "$UOUT" \
  && fail "a scan it could not account for reported itself complete: $(cat "$UOUT")"

echo "PASS: vaultkeeper-tick"
