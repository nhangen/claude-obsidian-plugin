#!/usr/bin/env bash
# frontmatter.sh — read top-level YAML frontmatter keys and report gaps.
# Top-level keys only: lines matching ^<key>: ... . Nested/list lines (leading
# whitespace, "- item") are intentionally ignored.

frontmatter_block() {
  awk '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm { print }
  ' "$1"
}

frontmatter_keys() {
  frontmatter_block "$1" | sed -n 's/^\([A-Za-z0-9_-]\{1,\}\):.*$/\1/p'
}

frontmatter_missing() {
  local present k
  present="$(frontmatter_keys "$1")"
  for k in $2; do
    grep -qxF "$k" <<<"$present" || printf '%s\n' "$k"
  done
}
