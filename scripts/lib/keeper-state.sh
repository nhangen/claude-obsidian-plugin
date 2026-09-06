#!/usr/bin/env bash
# keeper-state.sh — non-synced per-host state: cache dir, prior-scan snapshot,
# last_scan, last_attempt, cold-start detection, staleness banner. Requires
# note-hash.sh.
#
# The banner also reads two *synced* artifacts, but only where the host has no
# local state to speak from (#95): Librarian.md, whose shape surfacing.sh owns,
# and the lease dir, whose shape keeper-lease.sh owns.

keeper_vault_id() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "${out:-}" ] && command -v sha256sum >/dev/null 2>&1; then
    out="$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "${out:-}" ]; then
    printf 'keeper_vault_id: no sha256 tool (shasum/sha256sum) available\n' >&2
    return 1
  fi
  printf '%s' "${out:0:16}"
}

keeper_cache_dir() {
  printf '%s/vaultkeeper/%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}" "$(keeper_vault_id "$1")"
}

keeper_state_init() {
  local d; d="$(keeper_cache_dir "$1")"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

keeper_snapshot_file() { printf '%s/candidates.snapshot\n' "$(keeper_cache_dir "$1")"; }
keeper_has_snapshot()  { [ -f "$(keeper_snapshot_file "$1")" ]; }
keeper_read_snapshot() { local f; f="$(keeper_snapshot_file "$1")"; [ -f "$f" ] && cat "$f" || true; }

keeper_write_snapshot() {
  local f tmp; f="$(keeper_snapshot_file "$1")"
  mkdir -p "$(dirname "$f")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/snap-XXXXXX")" || return 1
  sort -u > "$tmp"
  keeper_swap_or_clean "$tmp" "$f"
}

# Read an epoch state file. Three outcomes, because the banner has to tell them
# apart (#94): rc 0 and the value (a usable timestamp), rc 1 (no file — nothing
# has happened on this host yet), rc 2 (the file is there but holds no
# timestamp). `>` truncates on open and can then fail on write, which is how
# ENOSPC leaves a zero-byte file behind — so "exists but empty" is a real
# degraded shape, and reading it as "absent" puts a faulting host back in the
# silence #49 and #52 exist to remove. An unreadable file (permissions) lands
# in the same branch: cat fails, the value is empty, and neither is a state to
# stay quiet about.
keeper_read_ts() {
  local f="$1" v
  [ -f "$f" ] || return 1
  v="$(cat "$f" 2>/dev/null || true)"
  case "$v" in
    ''|*[!0-9]*) return 2 ;;
  esac
  printf '%s\n' "$v"
}

# Stage and swap rather than writing in place, so a failed or partial write
# leaves the previous timestamp rather than a zero-byte file that reads as a
# state nobody is in. The temp file is staged in the target's own directory:
# a $TMPDIR on another filesystem makes the mv a copy, which is what this is
# avoiding. Returns non-zero on failure — vaultkeeper-tick.sh checks it.
keeper_write_ts() {
  local f="$1" d tmp
  d="$(dirname "$f")"
  mkdir -p "$d" || return 1
  tmp="$(mktemp "$d/.ts-XXXXXX")" || return 1
  now_epoch > "$tmp" || { rm -f "$tmp"; return 1; }
  keeper_swap_or_clean "$tmp" "$f"
}

keeper_last_scan_file() { printf '%s/last_scan\n' "$(keeper_cache_dir "$1")"; }
keeper_record_scan()    { keeper_write_ts "$(keeper_last_scan_file "$1")"; }
keeper_last_scan()      { keeper_read_ts "$(keeper_last_scan_file "$1")" || true; }

# An attempt is recorded by the elected owner immediately before it scans, whether or
# not that scan goes on to complete. It is what makes an absent last_scan legible: with
# no attempt nothing has tried from this host, and with one every try faulted.
keeper_last_attempt_file() { printf '%s/last_attempt\n' "$(keeper_cache_dir "$1")"; }
keeper_record_attempt()    { keeper_write_ts "$(keeper_last_attempt_file "$1")"; }
keeper_last_attempt()      { keeper_read_ts "$(keeper_last_attempt_file "$1")" || true; }

# What the vault itself says about the index, for a host with no local state of
# its own. Only the elected owner scans, and keeper state is per-host and never
# synced, so a deferring host has neither a scan nor an attempt and used to stay
# silent unconditionally — whether the owner was healthy or had faulted on every
# tick since install (#95). On a two-host vault the deferring host is usually
# where /obsidian:ask is being run.
#
# It reads the evidence that *is* synced rather than manufacturing local
# evidence: hoisting keeper_record_attempt above the ownership gate makes a
# deferring host claim an attempt it never makes and warn forever, on a vault
# the owner is scanning perfectly well (tests/vaultkeeper-tick.sh pins that).
#
# Echoes a banner line, or nothing when the vault reports a healthy scan.
keeper_vault_health() {
  local vault="$1" interval="$2" prio="${3:-}" digest="$1/Librarian.md"
  local lease="$1/.vaultkeeper" owner="" suffix="" status last now

  # No claim by any host means the keeper has never run anywhere — not a fault,
  # and not this host's to report. A vault nobody has ever pointed the keeper at
  # must stay quiet.
  [ -d "$lease" ] || return 0
  local has_claim=0 c
  for c in "$lease"/.keeper-claim-*; do
    if [ -e "$c" ]; then
      has_claim=1
      break
    fi
  done
  [ "$has_claim" -eq 1 ] || return 0

  # Name the owner when the caller has sourced keeper-lease.sh; election is that
  # file's business, and a banner is not worth a second implementation of it.
  if command -v keeper_elect >/dev/null 2>&1; then
    owner="$(keeper_elect "$lease" "$prio" "$(( interval * 2 ))" || true)"
  fi
  [ -n "$owner" ] && suffix=" (owner: $owner)"

  if [ ! -f "$digest" ]; then
    printf '⚠ no host has produced an index digest for this vault%s\n' "$suffix"
    return 0
  fi
  status="$(grep '^scan_status:' "$digest" 2>/dev/null | head -1 | sed 's/^scan_status:[[:space:]]*//')"
  if [ "$status" = "INCOMPLETE" ]; then
    printf '⚠ the last index scan faulted%s — see Librarian.md\n' "$suffix"
    return 0
  fi
  # A digest nobody has refreshed is the shape a dead owner leaves: it never
  # gets to stamp INCOMPLETE. Same 2x grace the local branch allows, which also
  # covers replication lag.
  last="$(grep '^last_scan:' "$digest" 2>/dev/null | head -1 | sed 's/^last_scan:[[:space:]]*//')"
  case "$last" in
    ''|*[!0-9]*)
      printf '⚠ the index digest for this vault is unreadable%s\n' "$suffix"
      return 0
      ;;
  esac
  now="$(now_epoch)"
  if [ "$(( now - last ))" -gt "$(( interval * 2 ))" ]; then
    printf '⚠ index last maintained %ss ago%s\n' "$(( now - last ))" "$suffix"
  fi
}

# The banner is the only place a user hears that the index is not being
# maintained. It used to return silently when last_scan was absent, which is
# indistinguishable from a fresh successful scan — and absent is exactly what a
# host whose *first* scan faulted has, because the tick withholds last_scan on a
# fault. Such a host reported nothing wrong, permanently (#52).
#
# The "has anything tried here" test is a recorded attempt, not the presence of the
# cache dir. keeper_state_init creates that dir at the top of every tick — above the
# ownership gate — so on a two-host vault it exists on the host that only ever defers,
# and keying off it warned there on every ask, forever, about a vault the elected owner
# was scanning perfectly well. A banner that always fires carries no information, which
# is a worse failure than the silence #52 removed. The attempt file is written below
# that gate, so only a host that actually scans has one.
# $3 (optional) is the configured host priority, forwarded to the election that
# names the owner in a vault-sourced line; without it the banner still fires,
# just unattributed.
staleness_banner() {
  local vault="$1" interval="$2" prio="${3:-}" last attempted now scan_rc=0 att_rc=0
  last="$(keeper_read_ts "$(keeper_last_scan_file "$vault")")" || scan_rc=$?
  if [ "$scan_rc" = "2" ]; then
    # Empty or non-numeric. Neither "healthy" nor "never scanned" is a claim
    # this host can make from that, and the arithmetic below would abort the
    # caller (ask-staleness.sh runs under set -e), whose consumers all read a
    # missing line as healthy.
    printf '⚠ index last_scan is unreadable on this host\n'
    return 0
  fi
  if [ "$scan_rc" != "0" ]; then
    attempted="$(keeper_read_ts "$(keeper_last_attempt_file "$vault")")" || att_rc=$?
    # Nothing has tried from this host. That is not evidence of health — on a
    # deferring host it is the normal state — so ask the vault (#95).
    [ "$att_rc" = "1" ] && { keeper_vault_health "$vault" "$interval" "$prio"; return 0; }
    if [ "$att_rc" != "0" ]; then
      printf '⚠ index last_attempt is unreadable on this host\n'
      return 0
    fi
    # No aging grace here, deliberately: one recorded attempt with no completed scan
    # already means the index has never been fully built on this host. The window
    # between the attempt and the scan is however long one tick's scanners take, so on
    # a first-ever tick over a large vault a healthy in-progress scan can show this
    # line until it finishes — accepted, because a grace window is what let a latched
    # fault hide in the first place.
    printf '⚠ index has never completed a scan on this host (last attempt %ss ago)\n' \
      "$(( $(now_epoch) - attempted ))"
    return 0
  fi
  now="$(now_epoch)"
  if [ "$(( now - last ))" -gt "$(( interval * 2 ))" ]; then
    printf '⚠ index last maintained %ss ago\n' "$(( now - last ))"
  fi
}
