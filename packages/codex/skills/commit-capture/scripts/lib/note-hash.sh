#!/usr/bin/env bash
# note-hash.sh — content hashing + portable stat helpers for the librarian.

sha256_of() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "${out:-}" ] && command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "${out:-}" ]; then
    printf 'sha256_of: no sha256 tool (shasum/sha256sum) available\n' >&2
    return 1
  fi
  printf '%s' "$out"
}

note_hash() {
  local f="$1" size sha
  size="$(wc -c < "$f" | tr -d ' ')"
  sha="$(sha256_of "$f")"
  printf '%s:%s\n' "$size" "$sha"
}

note_hash_valid() {
  [[ "$1" =~ ^[0-9]+:[0-9a-f]{64}$ ]]
}

# BSD stat spells mtime `-f %m`, GNU stat `-c %Y`. Probing by failure does not
# separate them: GNU stat reads `-f` as "report the FILESYSTEM", so on Linux the
# BSD probe SUCCEEDS and returns a block of filesystem stats. Every caller then
# had a non-numeric mtime — vault_index_plan compared it with `-gt` and errored
# per file, silently falling back to hashing every note it walked. So validate
# the answer rather than trusting the exit status, and take whichever spelling
# actually yields an epoch.
file_mtime() {
  local mt
  for mt in "$(stat -f %m "$1" 2>/dev/null)" "$(stat -c %Y "$1" 2>/dev/null)"; do
    case "$mt" in
      ''|*[!0-9]*) continue ;;
      *) printf '%s\n' "$mt"; return 0 ;;
    esac
  done
  printf 'file_mtime: cannot stat %s\n' "$1" >&2
  return 1
}

now_epoch() {
  date +%s
}

keeper_sha256_text() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "${out:-}" ] && command -v sha256sum >/dev/null 2>&1; then
    out="$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}')"
  fi
  [ -n "${out:-}" ] || { printf 'keeper: no sha256 tool available for lock key\n' >&2; return 1; }
  printf '%s\n' "$out"
}

keeper_test_pause() {
  local point="$1" dir="${KEEPER_TEST_PAUSE_DIR:-}"
  [ "${KEEPER_TEST_PAUSE_POINT:-}" = "$point" ] || return 0
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" || return 1
  : > "$dir/ready" || return 1
  while [ ! -e "$dir/continue" ]; do sleep 0.01; done
}

keeper_lock_acquire() {
  local key="$1" root lock candidate start now owner owner_token age stale reap token published reaped_owner reaped_token lock_kind
  local timeout="${KEEPER_LOCK_TIMEOUT_SECONDS:-30}"
  local stale_after="${KEEPER_LOCK_STALE_SECONDS:-2}"
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  case "$stale_after" in ''|*[!0-9]*) stale_after=2 ;; esac
  root="/tmp/claude-obsidian-keeper-$(id -u)"
  mkdir -p "$root" || return 1
  chmod 700 "$root" 2>/dev/null || true
  lock="$root/$(keeper_sha256_text "$key").lock"
  token="$$.$(now_epoch).${RANDOM:-0}"
  candidate="$root/.keeper-candidate-$$-${RANDOM:-0}"
  if ! printf '%s\n%s\n' "$$" "$token" > "$candidate"; then
    rm -f "$candidate" 2>/dev/null || true
    return 1
  fi
  if ! keeper_test_pause before_lock_owner; then
    rm -f "$candidate" 2>/dev/null || true
    return 1
  fi
  start="$(now_epoch)"
  while :; do
    owner=""
    owner_token=""
    lock_kind=""
    if [ -d "$lock" ]; then
      lock_kind=dir
      owner="$(sed -n '1p' "$lock/owner" 2>/dev/null || true)"
      owner_token="$(sed -n '2p' "$lock/owner" 2>/dev/null || true)"
    elif [ -f "$lock" ]; then
      lock_kind=file
      owner="$(sed -n '1p' "$lock" 2>/dev/null || true)"
      owner_token="$(sed -n '2p' "$lock" 2>/dev/null || true)"
    else
      if ln "$candidate" "$lock" 2>/dev/null; then
        rm -f "$candidate" 2>/dev/null || true
        if ! keeper_test_pause after_lock_owner; then
          rm -f "$lock" 2>/dev/null || true
          return 1
        fi
        printf '%s|%s\n' "$lock" "$token"
        return 0
      fi
      if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
        continue
      fi
      sleep 0.05
      continue
    fi
    now="$(now_epoch)"
    age=0
    if [ "$lock_kind" = dir ] || [ "$lock_kind" = file ]; then
      published="$(file_mtime "$lock" 2>/dev/null || printf '%s' "$now")"
      age=$(( now - published ))
    fi
    stale=0
    case "$owner" in
      ''|*[!0-9]*) [ "$age" -ge "$stale_after" ] && stale=1 ;;
      *)
        if [ "$age" -ge "$stale_after" ] && ! kill -0 "$owner" 2>/dev/null; then
          stale=1
        fi
        ;;
    esac
    if [ "$stale" = 1 ]; then
      reap="$lock.reaping.$$.$now.${RANDOM:-0}"
      if mv "$lock" "$reap" 2>/dev/null; then
        keeper_test_pause after_lock_reap || {
          rm -f "$candidate" 2>/dev/null || true
          return 1
        }
        if [ "$lock_kind" = dir ]; then
          reaped_owner="$(sed -n '1p' "$reap/owner" 2>/dev/null || true)"
          reaped_token="$(sed -n '2p' "$reap/owner" 2>/dev/null || true)"
        else
          reaped_owner="$(sed -n '1p' "$reap" 2>/dev/null || true)"
          reaped_token="$(sed -n '2p' "$reap" 2>/dev/null || true)"
        fi
        if [ "$reaped_owner" != "$owner" ] || [ "$reaped_token" != "$owner_token" ]; then
          [ -e "$lock" ] || mv "$reap" "$lock" 2>/dev/null || true
        else
          if [ "$lock_kind" = dir ]; then
            rm -f "$reap/owner" 2>/dev/null || true
            rmdir "$reap" 2>/dev/null || true
          else
            rm -f "$reap" 2>/dev/null || true
          fi
        fi
      fi
    fi
    if [ $(( now - start )) -ge "$timeout" ]; then
      printf 'keeper: timed out waiting for local write lock\n' >&2
      rm -f "$candidate" 2>/dev/null || true
      return 1
    fi
    sleep 0.05
  done
}

keeper_lock_release() {
  local record="$1" lock token owner published
  lock="${record%%|*}"
  token="${record#*|}"
  if [ -d "$lock" ]; then
    owner="$(sed -n '1p' "$lock/owner" 2>/dev/null || true)"
    published="$(sed -n '2p' "$lock/owner" 2>/dev/null || true)"
  else
    owner="$(sed -n '1p' "$lock" 2>/dev/null || true)"
    published="$(sed -n '2p' "$lock" 2>/dev/null || true)"
  fi
  [ "$owner" = "$$" ] && [ "$published" = "$token" ] || return 1
  if [ -d "$lock" ]; then
    rm -f "$lock/owner" 2>/dev/null || return 1
    rmdir "$lock" 2>/dev/null
  else
    rm -f "$lock" 2>/dev/null
  fi
}

keeper_with_lock() {
  local key="$1" lock rc
  shift
  lock="$(keeper_lock_acquire "$key")" || return 1
  if "$@"; then rc=0; else rc=$?; fi
  keeper_lock_release "$lock" \
    || printf 'keeper: warning — local write lock release failed; manual cleanup may be required\n' >&2
  return "$rc"
}

keeper_fault() {
  [ "${KEEPER_FAULT_INJECT:-}" = "$1" ] || return 0
  printf 'keeper: injected fault at %s\n' "$1" >&2
  return 91
}

# Atomic replace, or clean up after yourself. Every render-to-temp-then-swap site
# used a bare `mv`, so a failed swap left the temp behind (#43) — and one of them
# mktemps into the *vault root*, where the leak is visible in Obsidian and Syncthing
# replicates it to every host. PR #41 fixed one site; a helper is here so a caller
# cannot opt out by forgetting.
#
# Lives in note-hash.sh because it is the one lib every consumer of this pattern
# already sources first (the tick, and each affected lib's own suite).
#
# mv's own stderr is left alone: it names the reason (permissions, full disk, cross
# device), and this adds which file was being replaced rather than replacing that.
keeper_swap_or_clean() {
  local tmp="$1" target="$2"
  if mv "$tmp" "$target"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  printf 'keeper: could not replace %s; the staged temp file was discarded\n' "$target" >&2
  return 1
}
