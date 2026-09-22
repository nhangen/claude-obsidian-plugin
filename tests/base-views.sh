#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/base-views.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/base-views-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
T="$TMP/_vaultkeeper.base"

base_view_write "$TMP" "$T"
[ -f "$T" ] || fail "base file not created"
H1="$(note_hash "$T")"

# Idempotent: a second write with identical content must not rewrite the file.
MT1="$(file_mtime "$T")"
sleep 1
base_view_write "$TMP" "$T"
MT2="$(file_mtime "$T")"
[ "$MT1" = "$MT2" ] || fail "idempotent write changed mtime (rewrote unchanged file)"
[ "$(note_hash "$T")" = "$H1" ] || fail "content changed on idempotent write"

# Drift: external edit is corrected on next write.
printf 'tampered\n' > "$T"
base_view_write "$TMP" "$T"
[ "$(note_hash "$T")" = "$H1" ] || fail "drift not corrected"

OUTSIDE="$TMP-outside"; mkdir -p "$OUTSIDE"
ln -s "$OUTSIDE/escaped.base" "$TMP/escape.base"
base_view_write "$TMP" "$TMP/escape.base" 2>/dev/null \
  && fail "base view followed a symlink outside the vault"
[ ! -e "$OUTSIDE/escaped.base" ] || fail "base view wrote outside the vault"

echo "PASS: base-views"
