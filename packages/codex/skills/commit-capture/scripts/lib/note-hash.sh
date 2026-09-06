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
