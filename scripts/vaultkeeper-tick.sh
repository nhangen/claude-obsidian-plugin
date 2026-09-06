#!/usr/bin/env bash
# vaultkeeper-tick.sh — one deterministic substrate tick (no LLM). Runs on
# cron (ML-1) / launchd (MBP). Owner-gated shared writes; quarantine + scan +
# surface only as the elected owner. State is non-synced (under XDG cache).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/frontmatter.sh"
. "${ROOT}/lib/vault-scan.sh"
. "${ROOT}/lib/base-views.sh"
. "${ROOT}/lib/keeper-state.sh"
. "${ROOT}/lib/keeper-lease.sh"
. "${ROOT}/lib/surfacing.sh"
. "${ROOT}/lib/resolve-config.sh"

CONFIG="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}")" || {
  echo "vaultkeeper: no config; run /obsidian:setup" >&2; exit 0; }

cfg_val() { grep "^$1:" "$CONFIG" | head -1 | sed "s/^$1: *//"; }
VAULT="$(cfg_val vault_path)"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || { echo "vaultkeeper: vault not found: $VAULT" >&2; exit 0; }

REQUIRED="$(cfg_val frontmatter_required)"; REQUIRED="${REQUIRED:-tags type}"
PRIORITY="$(cfg_val keeper_host_priority | tr ' ' ',')"
INTERVAL="$(cfg_val keeper_interval_secs)"; INTERVAL="${INTERVAL:-900}"
MAXAGE=$(( INTERVAL * 2 ))
HOST="${VAULTKEEPER_HOST:-$(hostname -s)}"
LEASE="$VAULT/.vaultkeeper"

keeper_state_init "$VAULT" >/dev/null
keeper_claim_write "$LEASE" "$HOST"

if ! keeper_is_owner "$LEASE" "$HOST" "$PRIORITY" "$MAXAGE"; then
  echo "vaultkeeper: $HOST defers to $(keeper_elect "$LEASE" "$PRIORITY" "$MAXAGE")" >&2
  exit 0
fi

SCAN_FAULT=""
# Record the attempt here — below the ownership gate, above the scanners. It is what
# lets staleness_banner read a missing last_scan: no attempt means nothing has tried
# from this host, an attempt with no scan means every try faulted. It must stay below
# the gate, or a host that only ever defers claims an attempt it never makes and warns
# on every ask forever (keeper_state_init, and so the cache dir the banner used to key
# off, runs above the gate — which is exactly how that false alarm got shipped).
#
# Guarded rather than called bare: unchecked under `set -e` a failed write kills the
# tick right here, above the scan, the base view and the digest, so a full or unwritable
# cache dir would cost a degraded host the Librarian.md it can still produce. ENOSPC
# here is the same correlated failure class as the mktemp buffer below, so it takes the
# same route — fold into SCAN_FAULT and carry on. A scan whose attempt could not be
# recorded is not one we can account for.
if ! keeper_record_attempt "$VAULT"; then
  SCAN_FAULT="cannot record the scan attempt (cache dir unwritable); scan not accountable"
  printf 'vaultkeeper: %s\n' "$SCAN_FAULT" >&2
fi

# Capture the scanners' stderr instead of letting it fly past. Every scanner
# returns 0 unconditionally, so a truncated scan was indistinguishable from a
# complete one and got recorded as complete — for every one of 700+ consecutive
# ticks on the maintainer's host, each logging `Too many open files` immediately
# above `scan complete`. A scan whose scanners complained is not a scan we can
# describe as done; the gate below sits between the digest and the snapshot.
SCAN_ERR="$(mktemp "${TMPDIR:-/tmp}/kbscan-XXXXXX" 2>/dev/null)" || SCAN_ERR=""
if [ -n "$SCAN_ERR" ]; then
  :
else
  # Fail closed. With no buffer the fault check can never fire, and failing open
  # here restored the exact bug this gate removes — a partial scan recorded as
  # complete, silently. mktemp is also among the first casualties of the fd and
  # disk exhaustion the gate is watching for, so this is a correlated failure, not
  # an independent one.
  SCAN_FAULT="cannot create the scan-fault buffer (mktemp failed); scan not verifiable"
fi
# Permanently-unreadable paths are not a fault (#51). One `chmod 000` directory, or
# an iCloud path macOS TCC refuses, made `find` print `Permission denied` — and the
# gate, which could only see bytes on stderr, then reported INCOMPLETE on every tick
# from then on and never recorded last_scan. No tick can fix such a path, so there
# was no recovery: a vault whose readable notes were all scanned looked permanently
# broken. vault-scan.sh now separates the two, routing these here to be counted.
SCAN_UNREADABLE=""
KEEPER_SCAN_UNREADABLE_FILE="$(mktemp "${TMPDIR:-/tmp}/kbunread-XXXXXX" 2>/dev/null)" \
  || KEEPER_SCAN_UNREADABLE_FILE=""
if [ -n "$KEEPER_SCAN_UNREADABLE_FILE" ]; then
  export KEEPER_SCAN_UNREADABLE_FILE
else
  # Unlike the fault buffer, failing open here is the safe direction: with nowhere
  # to record them, the unreadable lines stay on stderr and land in SCAN_FAULT — the
  # old over-triggering behaviour, which is loud rather than silent.
  unset KEEPER_SCAN_UNREADABLE_FILE
fi
# One trap for both buffers, set once they are both decided. A tick killed for
# overrunning its launchd window otherwise leaks a file every 15 minutes — and
# `rm -f ""` is not a no-op, so each path is guarded rather than interpolated bare.
cleanup_bufs() {
  [ -n "${SCAN_ERR:-}" ] && rm -f "$SCAN_ERR" 2>/dev/null
  [ -n "${KEEPER_SCAN_UNREADABLE_FILE:-}" ] && rm -f "$KEEPER_SCAN_UNREADABLE_FILE" 2>/dev/null
  return 0
}
trap cleanup_bufs EXIT
# Quarantine runs here, INSIDE the fault capture, and its status is kept (#53). It
# used to run above — before the buffer even existed — with `|| true`, so a failed
# `mv` printed `failed to quarantine …` straight past the gate and the non-zero exit
# was discarded: the QUARANTINE list came back short and the tick recorded the scan
# as complete. Same invariant as the scanners, one function over.
#
# It stays above the digest so its rows appear in Librarian.md. That its rows cannot
# reach Pending.md on a faulted tick is a separate, filed problem (#58) — the move is
# irreversible and no later tick re-derives the row.
CAND="$( {
  # First inside the group, not before it (#53). Before it, `CONFLICTS="$(… || true)"`
  # ran while the buffer did not exist yet — and even appending to the buffer would
  # not have worked, because the group's own `2>"$SCAN_ERR"` truncates the file when
  # it opens. So a failed `mv` printed `failed to quarantine …` past the gate and
  # `|| true` discarded the status: the QUARANTINE list came back short and the tick
  # recorded the scan as complete. Inside, its stderr is the scanners' stderr.
  #
  # First and not last, because the scanners must not see the files it moves — run
  # after them, a conflict file that was quarantined successfully still shows up as a
  # frontmatter gap. Its rows go straight into CAND; the separate CONFLICTS variable
  # existed only to carry them across the group boundary.
  #
  # It stays above the digest so its rows reach Librarian.md. That its rows cannot
  # reach Pending.md on a faulted tick is a separate, filed problem (#58): the move is
  # irreversible and no later tick re-derives the row.
  keeper_quarantine_conflicts "$VAULT" \
    || printf 'keeper_quarantine_conflicts exited non-zero\n' >&2
  scan_frontmatter_gaps "$VAULT" "$REQUIRED"
  scan_unfiled "$VAULT"
  scan_open_asks "$VAULT"
  scan_clusters "$VAULT" 3
} 2>"${SCAN_ERR:-/dev/stderr}" | sed '/^$/d' )"
if [ -n "$SCAN_ERR" ] && [ -s "$SCAN_ERR" ]; then
  # Deduplicate before truncating. `_scan_find_md` backs three scanners, so one
  # unreadable directory yields the same `find: … Permission denied` line three
  # times; the 300-char clamp then spent the whole budget on the repetition and cut
  # off mid-word, hiding anything more serious further down. The buffer is the only
  # description of the fault the user gets, so what it drops matters.
  #
  # Newlines are kept through the control-character scrub so there are lines to
  # deduplicate, then folded to spaces afterwards for the one-line report. `sort -u`
  # costs the chronological order, which is worth less here than not losing a
  # distinct message.
  SCAN_FAULT="$(tr -c '[:print:]\n' ' ' < "$SCAN_ERR" | sed 's/ *$//' | sed '/^$/d' | sort -u | tr '\n' ' ')" \
    || SCAN_FAULT="unreadable"
  SCAN_FAULT="${SCAN_FAULT% }"
  # An unreadable-but-nonempty buffer must still read as a fault: empty here would
  # be read as "no fault" by every `-n "$SCAN_FAULT"` test below.
  [ -n "$SCAN_FAULT" ] || SCAN_FAULT="scanners wrote to stderr but the buffer could not be summarised"
  SCAN_FAULT="${SCAN_FAULT:0:300}"
  printf '%s\n' "$SCAN_FAULT" >&2
fi

# Unreadable paths get reported every tick, and separately from the fault, because
# they are a standing condition rather than an event: the count says "this many
# places I am not allowed to look", the scan of everything else is complete, and
# last_scan is recorded. Reported by count, not by path — the paths are absolute
# host paths, and the digest is replicated to every host (#56).
if [ -n "${KEEPER_SCAN_UNREADABLE_FILE:-}" ] && [ -s "$KEEPER_SCAN_UNREADABLE_FILE" ]; then
  SCAN_UNREADABLE="$(sort -u "$KEEPER_SCAN_UNREADABLE_FILE" | grep -c . | tr -d ' ')"
  [ "$SCAN_UNREADABLE" = "0" ] && SCAN_UNREADABLE=""
fi
if [ -n "$SCAN_UNREADABLE" ]; then
  printf 'vaultkeeper: %s path(s) unreadable on %s — every readable note was scanned; permissions are not something a tick can fix\n' \
    "$SCAN_UNREADABLE" "$HOST" >&2
fi

# These two stay above the gate because both survive a partial candidate set:
# base_view_write's content does not depend on CAND, and the digest is a full
# overwrite that nothing reads back. A permanently-faulting host therefore still
# surfaces something, which beats surfacing nothing — and the digest is told to say
# which it is. keeper_quarantine_conflicts has already moved any sync conflict
# irreversibly and emitted its row once, so that row cannot survive being withheld —
# the fault branch below appends it, and only it, for that reason (#58).
base_view_write "$VAULT/_vaultkeeper.base"
printf '%s\n' "$CAND" | surfacing_digest "$VAULT" "${SCAN_FAULT:+INCOMPLETE}" "$SCAN_UNREADABLE"

if [ -n "$SCAN_FAULT" ]; then
  # Stop before the snapshot. surfacing_pending_transition diffs against it and then
  # overwrites it, so a truncated set makes the next healthy tick re-append
  # everything this scan missed — 3 duplicated items over 4 fault/heal cycles when
  # this check sat below it, in a file the user hand-edits and Syncthing replicates.
  # keeper_record_scan is withheld for the ordinary reason: last_scan's consumer is
  # staleness_banner (scripts/ask-staleness.sh), and a partial scan recorded as
  # complete tells it the vault was fully examined. Withholding it reaches that consumer
  # even on a host that has never recorded one: the attempt written above the scanners
  # lets the banner tell a host whose every tick faulted from one that has never tried,
  # so a fault latched from the very first tick reads as "never completed a scan"
  # rather than as silence.
  #
  # One exception, and only one: rows whose side effect already happened and cannot be
  # re-derived (#58). keeper_quarantine_conflicts has already `mv`d the conflict file
  # and emitted its receipt once, and the file is excluded from every later walk — so a
  # QUARANTINE row withheld here is withheld permanently, and the user never learns a
  # sync conflict needs merging. Appended without touching the snapshot, which is what
  # keeps the transition gate intact: a row that cannot be re-derived cannot come back
  # through `comm -23` as new.
  QUARANTINE_ROWS="$(printf '%s\n' "$CAND" | grep '^QUARANTINE'$'\t' || true)"
  if [ -n "$QUARANTINE_ROWS" ]; then
    printf '%s\n' "$QUARANTINE_ROWS" | surfacing_pending_append "$VAULT"
  fi
  printf 'vaultkeeper: scan INCOMPLETE on %s — snapshot untouched%s; scanners said: %s\n' \
    "$HOST" "${QUARANTINE_ROWS:+, quarantine receipts appended to Pending.md}" "$SCAN_FAULT" >&2
  exit 0
fi

printf '%s\n' "$CAND" | surfacing_pending_transition "$VAULT"
# Guarded for the same reason as keeper_record_attempt above, and because
# keeper-state.sh documents this call as checked: bare under `set -e` a failed
# write aborts the tick here, after every shared write has already landed, so
# the run reads as a crash rather than as the one thing it could not record.
# The scan did complete; only the receipt is missing, and the banner's own
# unreadable-state branch covers a host that cannot write its state.
if ! keeper_record_scan "$VAULT"; then
  printf 'vaultkeeper: scan complete but last_scan could not be recorded (cache dir unwritable)\n' >&2
fi
echo "vaultkeeper: scan complete ($HOST)"
