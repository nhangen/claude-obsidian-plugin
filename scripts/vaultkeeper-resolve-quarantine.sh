#!/usr/bin/env bash
# vaultkeeper-resolve-quarantine.sh — inspect, diff, merge, and discard quarantined sync conflicts.
#
# Usage:
#   scripts/vaultkeeper-resolve-quarantine.sh list [--vault <dir>]
#   scripts/vaultkeeper-resolve-quarantine.sh diff <quarantine_file> [--vault <dir>]
#   scripts/vaultkeeper-resolve-quarantine.sh merge <quarantine_file> [--vault <dir>]
#   scripts/vaultkeeper-resolve-quarantine.sh discard <quarantine_file> [--vault <dir>]

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/keeper-state.sh"
. "${ROOT}/lib/keeper-lease.sh"
. "${ROOT}/lib/surfacing.sh"
. "${ROOT}/lib/resolve-config.sh"

_resolve_vault() {
  local v="${1:-}"
  if [ -z "$v" ]; then
    local cfg
    cfg="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}")" || true
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
      v="$(grep '^vault_path:' "$cfg" | head -1 | sed 's/^vault_path:[[:space:]]*//')"
    fi
  fi
  [ -n "$v" ] && [ -d "$v" ] || { printf 'error: vault not found or not specified\n' >&2; exit 1; }
  cd "$v" 2>/dev/null && pwd -P
}

_resolve_target_live() {
  local vault="$1" base="$2"
  # Quarantined filenames format: <epoch>-<basename>
  # where basename is like:
  #   Pending.sync-conflict-*.md -> Pending.md
  #   Librarian.sync-conflict-*.md -> Librarian.md
  #   _vaultkeeper.base.sync-conflict-* -> _vaultkeeper.base
  #   _vaultkeeper.sync-conflict-*.base -> _vaultkeeper.base
  #   <name>.sync-conflict-*.md -> <name>.md
  local clean="$base"
  clean="${clean#[0-9]*-}"
  case "$clean" in
    Pending.sync-conflict-*) printf '%s/Pending.md\n' "$vault" ;;
    Librarian.sync-conflict-*) printf '%s/Librarian.md\n' "$vault" ;;
    _vaultkeeper.base.sync-conflict-*|_vaultkeeper.sync-conflict-*.base) printf '%s/_vaultkeeper.base\n' "$vault" ;;
    *.sync-conflict-*.md)
      local stem="${clean%%.sync-conflict-*}"
      local found
      found="$(find "$vault" -type f -name "${stem}.md" ! -path '*/.vaultkeeper-quarantine/*' 2>/dev/null | head -1)"
      [ -n "$found" ] && printf '%s\n' "$found" || printf '%s/%s.md\n' "$vault" "$stem"
      ;;
    *)
      printf '%s/%s\n' "$vault" "$clean"
      ;;
  esac
}

cmd_list() {
  local vault="$1"
  local q_dir="$vault/.vaultkeeper-quarantine"
  if [ ! -d "$q_dir" ]; then
    printf 'Quarantine directory does not exist: %s\n' "$q_dir"
    return 0
  fi
  local files
  files="$(find "$q_dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | sort)"
  if [ -z "$files" ]; then
    printf 'Quarantine is empty.\n'
    return 0
  fi
  local count
  count="$(printf '%s\n' "$files" | grep -c . || true)"
  printf 'Quarantined conflicts (%s):\n' "$count"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local b sz
    b="$(basename "$f")"
    sz="$(wc -c < "$f" | tr -d ' ')"
    printf '  - %s (%s bytes)\n' "$b" "$sz"
  done <<<"$files"
}

cmd_diff() {
  local vault="$1" target="$2"
  local q_dir="$vault/.vaultkeeper-quarantine"
  local q_file="$q_dir/$(basename "$target")"
  [ -f "$q_file" ] || { printf 'error: quarantined file not found: %s\n' "$target" >&2; exit 1; }
  local live
  live="$(_resolve_target_live "$vault" "$(basename "$q_file")")"
  if [ ! -f "$live" ]; then
    printf 'Live note does not exist at %s\nShowing full quarantined copy (%s):\n' "$live" "$(basename "$q_file")"
    cat "$q_file"
    return 0
  fi
  printf '%s\n' "--- live: $live" "+++ quarantine: $q_file"
  diff -u "$live" "$q_file" || true
}

cmd_discard() {
  local vault="$1" target="$2"
  local q_dir="$vault/.vaultkeeper-quarantine"
  local q_file="$q_dir/$(basename "$target")"
  [ -f "$q_file" ] || { printf 'error: quarantined file not found: %s\n' "$target" >&2; exit 1; }
  [ ! -L "$q_file" ] || { printf 'error: refusing symlink %s\n' "$q_file" >&2; exit 1; }
  rm -f "$q_file"
  printf 'Discarded %s\n' "$(basename "$q_file")"
}

cmd_merge() {
  local vault="$1" target="$2"
  local q_dir="$vault/.vaultkeeper-quarantine"
  local q_file="$q_dir/$(basename "$target")"
  [ -f "$q_file" ] || { printf 'error: quarantined file not found: %s\n' "$target" >&2; exit 1; }
  [ ! -L "$q_file" ] || { printf 'error: refusing symlink %s\n' "$q_file" >&2; exit 1; }
  local b
  b="$(basename "$q_file")"

  # Machine-owned files: Librarian and _vaultkeeper.base are regenerated every tick
  case "$b" in
    *[0-9]-Librarian.sync-conflict-*|*[0-9]-_vaultkeeper.base.sync-conflict-*|*[0-9]-_vaultkeeper.sync-conflict-*.base)
      printf 'Machine-owned file %s is regenerated every tick; discarding quarantine copy.\n' "$b"
      rm -f "$q_file"
      return 0
      ;;
  esac

  # Pending.md: merge checklist items
  case "$b" in
    *[0-9]-Pending.sync-conflict-*)
      local pending="$vault/Pending.md"
      local added=0
      local line
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
          "- ["*"] "*)
            local payload
            payload="${line#- \[[^]]*\] }"
            if [ -f "$pending" ] && sed -n 's/^- \[[^]]*\] //p' "$pending" | grep -qxF -- "$payload"; then
              continue
            fi
            printf '%s\n' "$line" >> "$pending"
            added=$(( added + 1 ))
            ;;
        esac
      done < "$q_file"
      rm -f "$q_file"
      printf 'Merged %s item(s) into Pending.md and cleared %s\n' "$added" "$b"
      return 0
      ;;
  esac

  # Other files: show diff and instruction
  printf 'Manual resolution required for note %s.\n' "$b"
  cmd_diff "$vault" "$target"
}

main() {
  [ $# -ge 1 ] || {
    printf 'usage: vaultkeeper-resolve-quarantine.sh <list|diff|merge|discard> [args] [--vault <dir>]\n' >&2
    exit 1
  }
  local action="$1"; shift
  local vault="" target=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --vault) vault="${2:-}"; shift 2 ;;
      *)
        if [ -z "$target" ]; then target="$1"; shift; else shift; fi
        ;;
    esac
  done

  vault="$(_resolve_vault "$vault")"

  case "$action" in
    list) cmd_list "$vault" ;;
    diff)
      [ -n "$target" ] || { printf 'error: diff requires <quarantine_file>\n' >&2; exit 1; }
      cmd_diff "$vault" "$target"
      ;;
    discard)
      [ -n "$target" ] || { printf 'error: discard requires <quarantine_file>\n' >&2; exit 1; }
      cmd_discard "$vault" "$target"
      ;;
    merge)
      [ -n "$target" ] || { printf 'error: merge requires <quarantine_file>\n' >&2; exit 1; }
      cmd_merge "$vault" "$target"
      ;;
    *)
      printf 'unknown action: %s\n' "$action" >&2
      exit 1
      ;;
  esac
}

main "$@"
