#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/base-views.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/base-views-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
T="$TMP/_vaultkeeper.base"

base_view_write "$T"
[ -f "$T" ] || fail "base file not created"
H1="$(note_hash "$T")"

# Idempotent: a second write with identical content must not rewrite the file.
MT1="$(file_mtime "$T")"
sleep 1
base_view_write "$T"
MT2="$(file_mtime "$T")"
[ "$MT1" = "$MT2" ] || fail "idempotent write changed mtime (rewrote unchanged file)"
[ "$(note_hash "$T")" = "$H1" ] || fail "content changed on idempotent write"

# Drift: external edit is corrected on next write.
printf 'tampered\n' > "$T"
base_view_write "$T"
[ "$(note_hash "$T")" = "$H1" ] || fail "drift not corrected"

echo "PASS: base-views"
