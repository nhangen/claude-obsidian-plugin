#!/usr/bin/env bash
# seed-frontmatter-schema.sh — ONE-TIME: derive the dominant top-level
# frontmatter keys across the vault and seed `frontmatter_required:` into the
# config, only if absent. NOT run on the tick. Idempotent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/frontmatter.sh"

VAULT="${1:?usage: seed-frontmatter-schema.sh <vault_path> <config_file>}"
CFG="${2:?usage: seed-frontmatter-schema.sh <vault_path> <config_file>}"
THRESHOLD_PCT="${SCHEMA_THRESHOLD_PCT:-80}"

if grep -q '^frontmatter_required:' "$CFG"; then
  grep '^frontmatter_required:' "$CFG" | sed 's/frontmatter_required: *//'
  exit 0
fi

# NOTE: no associative arrays — the MacBook keeper host runs bash 3.2, which
# rejects `declare -A`. Count via a sort|uniq -c pipeline (matches existing
# scripts/lib style, which uses zero assoc arrays).
find_notes() {
  find "$VAULT" -type f -name '*.md' \
    ! -path '*/.obsidian/*' ! -path '*/.trash/*' ! -path '*/.git/*'
}
total="$(find_notes | wc -l | tr -d ' ')"

required=""
if [ "$total" -gt 0 ]; then
  # Stream one line per (note, distinct key); uniq -c => count of notes per key.
  while read -r cnt key; do
    [ -z "$cnt" ] && continue
    if [ "$(( cnt * 100 / total ))" -ge "$THRESHOLD_PCT" ]; then
      required="${required:+$required }$key"
    fi
  done < <(
    find_notes | while IFS= read -r f; do frontmatter_keys "$f" | sort -u; done \
      | sort | uniq -c
  )
fi
required="$(printf '%s\n' $required | sort | paste -sd' ' -)"

# Insert into the config frontmatter (after the opening ---).
tmp="$(mktemp "${TMPDIR:-/tmp}/cfg-XXXXXX")"
awk -v line="frontmatter_required: ${required}" '
  NR==1 && $0=="---" { print; print line; inserted=1; next }
  { print }
  END { if (!inserted) print line }
' "$CFG" > "$tmp"
mv "$tmp" "$CFG"
printf '%s\n' "$required"
