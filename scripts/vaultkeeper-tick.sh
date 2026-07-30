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

CONFLICTS="$(keeper_quarantine_conflicts "$VAULT" || true)"
# Capture the scanners' stderr instead of letting it fly past. Every scanner
# returns 0 unconditionally, so a truncated scan was indistinguishable from a
# complete one and got recorded as complete — for every one of 700+ consecutive
# ticks on the maintainer's host, each logging `Too many open files` immediately
# above `scan complete`. A scan whose scanners complained is not a scan we can
# describe as done; the gate below sits between the digest and the snapshot.
SCAN_FAULT=""
SCAN_ERR="$(mktemp "${TMPDIR:-/tmp}/kbscan-XXXXXX" 2>/dev/null)" || SCAN_ERR=""
if [ -n "$SCAN_ERR" ]; then
  # trap, not a bare rm below: a tick killed for overrunning its launchd window
  # otherwise leaks one buffer every 15 minutes, and the fault goes with it.
  trap 'rm -f "$SCAN_ERR"' EXIT
else
  # Fail closed. With no buffer the fault check can never fire, and failing open
  # here restored the exact bug this gate removes — a partial scan recorded as
  # complete, silently. mktemp is also among the first casualties of the fd and
  # disk exhaustion the gate is watching for, so this is a correlated failure, not
  # an independent one.
  SCAN_FAULT="cannot create the scan-fault buffer (mktemp failed); scan not verifiable"
fi
CAND="$( {
  scan_frontmatter_gaps "$VAULT" "$REQUIRED"
  scan_unfiled "$VAULT"
  scan_open_asks "$VAULT"
  scan_clusters "$VAULT" 3
  if [ -n "$CONFLICTS" ]; then printf '%s\n' "$CONFLICTS"; fi
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

# These two stay above the gate because both survive a partial candidate set:
# base_view_write's content does not depend on CAND, and the digest is a full
# overwrite that nothing reads back. A permanently-faulting host therefore still
# surfaces something, which beats surfacing nothing — and the digest is told to say
# which it is. Caveat: keeper_quarantine_conflicts (line 38) already moved any sync
# conflict irreversibly and emits its row once, so on a faulted tick that row never
# reaches Pending.md and no later tick can re-emit it. The file is safely in
# .vaultkeeper-quarantine either way; the missing checklist line is filed separately.
base_view_write "$VAULT/_vaultkeeper.base"
printf '%s\n' "$CAND" | surfacing_digest "$VAULT" "${SCAN_FAULT:+INCOMPLETE}"

if [ -n "$SCAN_FAULT" ]; then
  # Stop before the snapshot. surfacing_pending_transition diffs against it and then
  # overwrites it, so a truncated set makes the next healthy tick re-append
  # everything this scan missed — 3 duplicated items over 4 fault/heal cycles when
  # this check sat below it, in a file the user hand-edits and Syncthing replicates.
  # keeper_record_scan is withheld for the ordinary reason: last_scan's consumer is
  # staleness_banner (scripts/ask-staleness.sh), and a partial scan recorded as
  # complete tells it the vault was fully examined. Note the banner only fires once a
  # PREVIOUS last_scan ages out — a host that has never recorded one stays silent, so
  # a latched fault here is invisible rather than loud. That gap is filed separately.
  printf 'vaultkeeper: scan INCOMPLETE on %s — snapshot and Pending.md left untouched; scanners said: %s\n' \
    "$HOST" "$SCAN_FAULT" >&2
  exit 0
fi

printf '%s\n' "$CAND" | surfacing_pending_transition "$VAULT"
keeper_record_scan "$VAULT"
echo "vaultkeeper: scan complete ($HOST)"
