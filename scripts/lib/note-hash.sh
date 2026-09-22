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

keeper_lock_acquire() {
  local key="$1" root lock start now owner stale timeout="${KEEPER_LOCK_TIMEOUT_SECONDS:-30}"
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  root="/tmp/claude-obsidian-keeper-$(id -u)"
  mkdir -p "$root" || return 1
  chmod 700 "$root" 2>/dev/null || true
  lock="$root/$(keeper_sha256_text "$key").lock"
  start="$(now_epoch)"
  while ! mkdir "$lock" 2>/dev/null; do
    owner="$(sed -n '1p' "$lock/owner" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      stale="$lock.stale.$$.$(now_epoch)"
      if mv "$lock" "$stale" 2>/dev/null; then rm -rf "$stale"; fi
      continue
    fi
    now="$(now_epoch)"
    if [ -z "$owner" ] && [ $(( now - start )) -ge 5 ]; then
      stale="$lock.stale.$$.$now"
      if mv "$lock" "$stale" 2>/dev/null; then rm -rf "$stale"; fi
      continue
    fi
    if [ $(( now - start )) -ge "$timeout" ]; then
      printf 'keeper: timed out waiting for local write lock\n' >&2
      return 1
    fi
    sleep 0.05
  done
  if ! printf '%s\n' "$$" > "$lock/owner"; then
    rm -rf "$lock"
    return 1
  fi
  printf '%s\n' "$lock"
}

keeper_lock_release() {
  local lock="$1" owner
  owner="$(sed -n '1p' "$lock/owner" 2>/dev/null || true)"
  [ "$owner" = "$$" ] || return 1
  rm -f "$lock/owner" 2>/dev/null || return 1
  rmdir "$lock" 2>/dev/null
}

keeper_with_lock() {
  local key="$1" lock rc
  shift
  lock="$(keeper_lock_acquire "$key")" || return 1
  if "$@"; then rc=0; else rc=$?; fi
  keeper_lock_release "$lock" \
    || printf 'keeper: warning — local write lock will be reclaimed after process exit\n' >&2
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
