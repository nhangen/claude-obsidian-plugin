#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPER="$ROOT_DIR/scripts/keeper"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-fence-info-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
V="$TMP/vault"
mkdir -p "$V/.obsidian"
printf 'new checkpoint body\n' > "$TMP/b.md"

printf '%s\n' '```text' '```literal' '## 4444444 illustrative heading' '```' \
  '## 3333333 real checkpoint' > "$TMP/fence-info.md"
bash "$KEEPER" append --vault "$V" --target "Notes/fence-info.md" \
  --section '## init' --body-file "$TMP/fence-info.md" >/dev/null
FENCE_INFO_BEFORE="$(cat "$V/Notes/fence-info.md")"
bash "$KEEPER" append --vault "$V" --target "Notes/fence-info.md" \
  --section '## 3333333 repeated checkpoint' --body-file "$TMP/b.md" --skip-if-hash 3333333 >/dev/null
[ "$(cat "$V/Notes/fence-info.md")" = "$FENCE_INFO_BEFORE" ] \
  || fail 'a fence-like line carrying text hid a real checkpoint from retry deduplication'
bash "$KEEPER" append --vault "$V" --target "Notes/fence-info.md" \
  --section '## 4444444 real checkpoint' --body-file "$TMP/b.md" --skip-if-hash 4444444 >/dev/null
[ "$(cat "$V/Notes/fence-info.md")" != "$FENCE_INFO_BEFORE" ] \
  || fail 'a fence-like line carrying text exposed an illustrative heading as a real capture'

printf "ok keeper fence info\n"
