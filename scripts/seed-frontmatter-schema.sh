#!/usr/bin/env bash
# seed-frontmatter-schema.sh — ONE-TIME: derive the dominant top-level
# frontmatter keys across the vault and seed `frontmatter_required:` into the
# config, only if absent. NOT run on the tick. Idempotent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/frontmatter.sh"

VAULT="${1:?usage: seed-frontmatter-schema.sh <vault_path> <config_file>}"
CFG="${2:?usage: seed-frontmatter-schema.sh <vault_path> <config_file>}"
THRESHOLD_PCT="${SCHEMA_THRESHOLD_PCT:-80}"

# Already seeded — but only if it was seeded with something. A present-but-EMPTY
# `frontmatter_required:` is what this script itself writes when no key clears the
# threshold (or the vault is empty), and the presence test then short-circuits
# forever: the tick falls back to a hardcoded `tags type`, so the librarian nudges
# for keys the vault does not use, permanently, on the one host where a retry can
# never happen (#46). Empty is treated as not-yet-seeded so such a host self-heals.
EXISTING=""
EXISTING_LINE=""
if grep -q '^frontmatter_required:' "$CFG"; then
  EXISTING_LINE=1
  EXISTING="$(grep '^frontmatter_required:' "$CFG" | head -1 | sed 's/frontmatter_required: *//')"
  EXISTING="${EXISTING%$'\r'}"
  EXISTING="${EXISTING%"${EXISTING##*[![:space:]]}"}"
  if [ -n "$EXISTING" ]; then
    printf '%s\n' "$EXISTING"
    exit 0
  fi
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

# Nothing derived: do NOT write the key. Writing it empty is what stranded hosts on
# the hardcoded fallback with no way back — and an absent key is exactly what lets a
# later session, over a vault that has notes by then, try again. Says so on stderr,
# which the caller now quotes.
if [ -z "$required" ]; then
  printf 'seed-frontmatter-schema: no frontmatter key appears in >=%s%% of %s note(s) in %s; leaving frontmatter_required unset so a later session can retry\n' \
    "$THRESHOLD_PCT" "$total" "$VAULT" >&2
  exit 1
fi

# Insert into the config frontmatter (after the opening ---). A present-but-empty key
# is replaced rather than duplicated: a host healing from the bug above already has
# the line.
tmp="$(mktemp "${TMPDIR:-/tmp}/cfg-XXXXXX")" || exit 1
if [ -n "$EXISTING_LINE" ]; then
  awk -v line="frontmatter_required: ${required}" '
    /^frontmatter_required:/ && !done { print line; done=1; next }
    { print }
  ' "$CFG" > "$tmp" || { rm -f "$tmp"; exit 1; }
else
  awk -v line="frontmatter_required: ${required}" '
    NR==1 && $0=="---" { print; print line; inserted=1; next }
    { print }
    END { if (!inserted) print line }
  ' "$CFG" > "$tmp" || { rm -f "$tmp"; exit 1; }
fi
keeper_swap_or_clean "$tmp" "$CFG" || exit 1
printf '%s\n' "$required"
