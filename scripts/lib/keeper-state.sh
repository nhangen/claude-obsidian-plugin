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

# The banner is the only place a user hears that the index is not being
# maintained. It used to return silently when last_scan was absent, which is
# indistinguishable from a fresh successful scan — and absent is exactly what a
# host whose *first* scan faulted has, because the tick withholds last_scan on a
# fault. Such a host reported nothing wrong, permanently (#52).
#
# The cache dir is the "has the keeper ever run here" test: it is created by
# keeper_state_init at the top of every tick. Without that condition the banner
# would nag on any vault where the keeper was never installed, which is not a
# fault and not this warning's business.
staleness_banner() {
  local vault="$1" interval="$2" last now
  last="$(keeper_last_scan "$vault")"
  if [ -z "$last" ]; then
    [ -d "$(keeper_cache_dir "$vault")" ] || return 0
    printf '⚠ index has never completed a scan on this host\n'
    return 0
  fi
  # A last_scan that is not a number cannot be compared, and the arithmetic below
  # would abort the caller (ask-staleness.sh runs under set -e). Unreadable is a
  # state to report, not one to fall silent on.
  case "$last" in
    *[!0-9]*)
      printf '⚠ index last_scan is unreadable on this host\n'
      return 0
      ;;
  esac
  now="$(now_epoch)"
  if [ "$(( now - last ))" -gt "$(( interval * 2 ))" ]; then
    printf '⚠ index last maintained %ss ago\n' "$(( now - last ))"
  fi
}
