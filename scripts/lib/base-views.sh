#!/usr/bin/env bash
# base-views.sh — maintain the write-only Obsidian Bases view that renders
# frontmatter gaps inside the GUI. Requires note-hash.sh (keeper_swap_or_clean).
# WRITE-ONLY: no keeper code reads a .base to
# answer a query (headless reader is the frontmatter walk). Idempotent.

base_view_content() {
  cat <<'EOF'
filters:
  or:
    - '!file.hasProperty("tags")'
    - '!file.hasProperty("type")'
views:
  - type: table
    name: Frontmatter gaps
    order:
      - file.name
      - file.folder
EOF
}

base_view_write() {
  local target="$1" tmp
  tmp="$(mktemp "$(dirname "$target")/.base-XXXXXX")" || return 1
  base_view_content > "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi
  keeper_swap_or_clean "$tmp" "$target"
}
