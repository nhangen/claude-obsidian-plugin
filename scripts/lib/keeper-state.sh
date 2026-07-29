#!/usr/bin/env bash
# keeper-state.sh — non-synced per-host state: cache dir, prior-scan snapshot,
# last_scan, cold-start detection, staleness banner. Requires note-hash.sh.

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
  mv "$tmp" "$f"
}

keeper_last_scan_file() { printf '%s/last_scan\n' "$(keeper_cache_dir "$1")"; }
keeper_record_scan()    { local f; f="$(keeper_last_scan_file "$1")"; mkdir -p "$(dirname "$f")"; now_epoch > "$f"; }
keeper_last_scan()      { local f; f="$(keeper_last_scan_file "$1")"; [ -f "$f" ] && cat "$f" || true; }

# An attempt is recorded by the elected owner before it scans, whether or not that
# scan goes on to complete. It is what separates "no last_scan because nothing has
# ever tried" (fresh install, or a host that defers to the owner — silence is right)
# from "no last_scan because every attempt faulted" (the scan-fault gate withholding
# it, which is exactly the state worth shouting about).
keeper_last_attempt_file() { printf '%s/last_attempt\n' "$(keeper_cache_dir "$1")"; }
keeper_record_attempt()    { local f; f="$(keeper_last_attempt_file "$1")"; mkdir -p "$(dirname "$f")"; now_epoch > "$f"; }
keeper_last_attempt()      { local f; f="$(keeper_last_attempt_file "$1")"; [ -f "$f" ] && cat "$f" || true; }

staleness_banner() {
  local vault="$1" interval="$2" last attempted now
  last="$(keeper_last_scan "$vault")"
  now="$(now_epoch)"
  if [ -z "$last" ]; then
    attempted="$(keeper_last_attempt "$vault")"
    # No attempt on disk: nothing has tried to scan this vault from this host yet.
    [ -z "$attempted" ] && return 0
    # Attempted and still no completed scan. No aging grace here on purpose — one
    # faulted tick already means the index has never been fully built, and the
    # in-flight window between recording the attempt and recording the scan is
    # the couple of seconds a healthy tick takes.
    printf '⚠ index has never completed a scan (last attempt %ss ago)\n' "$(( now - attempted ))"
    return 0
  fi
  if [ "$(( now - last ))" -gt "$(( interval * 2 ))" ]; then
    printf '⚠ index last maintained %ss ago\n' "$(( now - last ))"
  fi
}
