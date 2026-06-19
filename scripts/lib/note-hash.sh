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

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"
}

now_epoch() {
  date +%s
}
