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

_base_view_write_locked() {
  local vault="$1" target="$2" tmp canonical_parent
  [ ! -L "$target" ] || return 1
  canonical_parent="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
  [ "$canonical_parent" = "$vault" ] || return 1
  target="$vault/$(basename "$target")"
  tmp="$(mktemp "$(dirname "$target")/.base-XXXXXX")" || return 1
  base_view_content > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi
  keeper_swap_or_clean "$tmp" "$target"
}

base_view_write() {
  local vault="$1" target="$2" canonical
  canonical="$(cd "$vault" 2>/dev/null && pwd -P)" || return 1
  keeper_with_lock "$canonical" _base_view_write_locked "$canonical" "$target"
}
