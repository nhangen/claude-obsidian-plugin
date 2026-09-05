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

# The two spellings cannot be told apart by exit status: GNU stat reads `-f` as
# a filesystem query and SUCCEEDS on it, returning a block of filesystem stats.
# Trusting that answer gave every caller a non-numeric mtime — vault_index_plan
# then errored per file and silently hashed every note it walked.
MT="$(file_mtime "$TMP/a.md")"
case "$MT" in
  ''|*[!0-9]*) fail "file_mtime returned a non-epoch: [$MT]" ;;
esac

# The real proof, on any host: stub `stat` so the BSD spelling behaves the way
# GNU stat does — `-f` SUCCEEDS and answers with filesystem stats. On a BSD host
# both assertions above pass with the old implementation too, since native
# `stat -f %m` returns a clean epoch there; only this case fails unless
# file_mtime validates the answer and falls through to `-c %Y`.
STUB="$TMP/stubbin"; mkdir -p "$STUB"
cat > "$STUB/stat" <<'STUBEOF'
#!/usr/bin/env bash
# GNU stat reads -f as "report the filesystem": exit 0, non-numeric output.
case "$1" in
  -f) printf '  File: "%s"
    ID: 0        Namelen: 255     Type: ext2/ext3
' "${3:-x}"; exit 0 ;;
  -c) [ "$2" = "%Y" ] && { printf '1712345678
'; exit 0; } ;;
esac
exit 1
STUBEOF
chmod +x "$STUB/stat"
STUBBED="$(PATH="$STUB:$PATH" bash -c ". '$ROOT_DIR/scripts/lib/note-hash.sh'; file_mtime '$TMP/a.md'")"   || fail "file_mtime failed when only the GNU spelling answers"
[ "$STUBBED" = "1712345678" ]   || fail "file_mtime trusted the exit status of a stat -f that answers with filesystem stats: [$STUBBED]"

# Neither spelling answering is a hard failure, not a fabricated epoch.
cat > "$STUB/stat" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
chmod +x "$STUB/stat"
PATH="$STUB:$PATH" bash -c ". '$ROOT_DIR/scripts/lib/note-hash.sh'; file_mtime '$TMP/a.md'" >/dev/null 2>&1   && fail "file_mtime succeeded when no stat spelling answered"
rm -rf "$STUB"

# A path no stat spelling can answer must fail loudly, not echo something the
# caller will do arithmetic on.
file_mtime "$TMP/definitely-not-here.md" >/dev/null 2>&1 \
  && fail "file_mtime succeeded on a missing file"

echo "PASS: note-hash"
