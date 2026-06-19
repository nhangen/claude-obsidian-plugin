#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/note-hash-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

printf 'hello world\n' > "$TMP/a.md"
H1="$(note_hash "$TMP/a.md")"
note_hash_valid "$H1" || fail "note_hash output not valid shape: $H1"

# identical content -> identical hash
printf 'hello world\n' > "$TMP/b.md"
[ "$(note_hash "$TMP/b.md")" = "$H1" ] || fail "same content should hash equal"

# body change -> different hash
printf 'hello WORLD\n' > "$TMP/a.md"
[ "$(note_hash "$TMP/a.md")" != "$H1" ] || fail "changed content should hash differently"

# validity rejects junk
note_hash_valid "garbage" && fail "should reject 'garbage'"
note_hash_valid "12:abc" && fail "should reject short hex"
note_hash_valid "" && fail "should reject empty"

# mtime + now are integers
M="$(file_mtime "$TMP/a.md")"; [[ "$M" =~ ^[0-9]+$ ]] || fail "file_mtime not integer: $M"
N="$(now_epoch)"; [[ "$N" =~ ^[0-9]+$ ]] || fail "now_epoch not integer: $N"

echo "PASS: note-hash"
