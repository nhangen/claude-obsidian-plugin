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

_validate_quarantine_file() {
  local vault="$1" target="$2"
  local q_dir="$vault/.vaultkeeper-quarantine"

  if [ -L "$q_dir" ]; then
    printf 'error: refusing symlink %s\n' "$q_dir" >&2
    return 1
  fi
  if [ ! -d "$q_dir" ]; then
    printf 'error: quarantined file not found: %s\n' "$target" >&2
    return 1
  fi

  local canonical_q
  canonical_q="$(cd "$q_dir" 2>/dev/null && pwd -P)" || {
    printf 'error: refusing symlink %s\n' "$q_dir" >&2
    return 1
  }
  if [ "$canonical_q" != "$q_dir" ]; then
    printf 'error: refusing symlink %s\n' "$q_dir" >&2
    return 1
  fi

  case "/$target/" in
    */../*)
      printf 'error: refusing path traversal in target: %s\n' "$target" >&2
      return 1
      ;;
  esac

  local rel="$target"
  if [ "${rel#/}" != "$rel" ]; then
    local target_dir canonical_target_dir
    target_dir="$(dirname "$rel")"
    canonical_target_dir="$(cd "$target_dir" 2>/dev/null && pwd -P)" || {
      printf 'error: quarantined file not found: %s\n' "$target" >&2
      return 1
    }
    if [ "$canonical_target_dir" != "$q_dir" ]; then
      printf 'error: refusing path outside .vaultkeeper-quarantine: %s\n' "$target" >&2
      return 1
    fi
    rel="$(basename "$rel")"
  else
    while [ "${rel#./}" != "$rel" ]; do
      rel="${rel#./}"
    done
    if [ "${rel#"$q_dir/"}" != "$rel" ]; then
      rel="${rel#"$q_dir/"}"
    elif [ "${rel#".vaultkeeper-quarantine/"}" != "$rel" ]; then
      rel="${rel#".vaultkeeper-quarantine/"}"
    fi

    case "$rel" in
      */*)
        printf 'error: refusing directory path in quarantine file: %s\n' "$target" >&2
        return 1
        ;;
    esac
  fi

  if [ -z "$rel" ]; then
    printf 'error: quarantined file not found: %s\n' "$target" >&2
    return 1
  fi

  local q_file="$q_dir/$rel"

  if [ -L "$q_file" ]; then
    printf 'error: refusing symlink %s\n' "$q_file" >&2
    return 1
  fi
  if [ ! -f "$q_file" ]; then
    printf 'error: quarantined file not found: %s\n' "$target" >&2
    return 1
  fi

  local parent_dir
  parent_dir="$(cd "$(dirname "$q_file")" 2>/dev/null && pwd -P)" || {
    printf 'error: could not resolve parent of %s\n' "$q_file" >&2
    return 1
  }
  if [ "$parent_dir" != "$q_dir" ]; then
    printf 'error: refusing symlink %s\n' "$q_file" >&2
    return 1
  fi

  printf '%s\n' "$q_file"
}

_resolve_vault() {
  local v="${1:-}"
  if [ -z "$v" ]; then
    v="$(obsidian_config_value vault_path "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}" || true)"
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
      # Quarantine flattens the conflict's folder away, so the stem is all there is to
      # go on. Prefer the vault-root copy, and say so whenever more than one note
      # shares the stem, since the pick may be the wrong one (#190).
      local found count pick
      found="$(find "$vault" -type f -name "${stem}.md" ! -path '*/.vaultkeeper-quarantine/*' 2>/dev/null | LC_ALL=C sort || true)"
      count="$(printf '%s' "$found" | grep -c . || true)"
      if [ -f "$vault/${stem}.md" ]; then
        pick="$vault/${stem}.md"
      elif [ -n "$found" ]; then
        pick="$(printf '%s\n' "$found" | head -1)"
      else
        pick="$vault/${stem}.md"
      fi
      if [ "$count" -gt 1 ]; then
        printf 'warning: %s notes named %s.md; diffing against %s\n' "$count" "$stem" "$pick" >&2
        printf '%s\n' "$found" >&2
      fi
      printf '%s\n' "$pick"
      ;;
    *)
      printf '%s/%s\n' "$vault" "$clean"
      ;;
  esac
}

cmd_list() {
  local vault="$1"
  local q_dir="$vault/.vaultkeeper-quarantine"
  if [ -L "$q_dir" ]; then
    printf 'error: refusing symlink %s\n' "$q_dir" >&2
    return 1
  fi
  if [ ! -d "$q_dir" ]; then
    printf 'Quarantine directory does not exist: %s\n' "$q_dir"
    return 0
  fi
  local canonical_q
  canonical_q="$(cd "$q_dir" 2>/dev/null && pwd -P)" || {
    printf 'error: refusing symlink %s\n' "$q_dir" >&2
    return 1
  }
  if [ "$canonical_q" != "$q_dir" ]; then
    printf 'error: refusing symlink %s\n' "$q_dir" >&2
    return 1
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
  local q_file
  q_file="$(_validate_quarantine_file "$vault" "$target")" || return 1
  local live
  live="$(_resolve_target_live "$vault" "$(basename "$q_file")")"
  if [ -L "$live" ]; then
    printf 'error: refusing symlink %s\n' "$live" >&2
    return 1
  fi
  if [ ! -f "$live" ]; then
    printf 'Live note does not exist at %s\nShowing full quarantined copy (%s):\n' "$live" "$(basename "$q_file")"
    cat "$q_file"
    return 0
  fi
  printf '%s\n' "--- live: $live" "+++ quarantine: $q_file"
  diff -u "$live" "$q_file" || [ $? -eq 1 ]
}

_discard_locked() {
  local vault="$1" target="$2"
  local q_file
  q_file="$(_validate_quarantine_file "$vault" "$target")" || return 1
  rm -f "$q_file"
  printf 'Discarded %s\n' "$(basename "$q_file")"
}

cmd_discard() {
  local vault="$1" target="$2"
  keeper_with_lock "$vault" _discard_locked "$vault" "$target"
}

# Runs under keeper_with_lock, same as the tick's Pending.md writer, so a merge cannot
# race a tick's swap. Sets MERGE_ADDED and MERGE_SKIPPED for the caller.
_merge_pending_locked() {
  local vault="$1" q_file="$2" pending="$1/Pending.md" tmp line payload
  [ ! -L "$pending" ] || { printf 'error: refusing symlink %s\n' "$pending" >&2; return 1; }
  tmp="$(mktemp "$vault/.Pending-XXXXXX")" || return 1
  if [ -f "$pending" ]; then
    cp "$pending" "$tmp" || { rm -f "$tmp"; return 1; }
    if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then
      printf '\n' >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      "- ["*"] "*)
        payload="${line#- \[[^]]*\] }"
        if sed -n 's/^- \[[^]]*\] //p' "$tmp" | grep -qxF -- "$payload"; then
          continue
        fi
        printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
        MERGE_ADDED=$(( MERGE_ADDED + 1 ))
        ;;
      *)
        if grep -qxF -- "$line" "$tmp"; then
          continue
        fi
        MERGE_SKIPPED="${MERGE_SKIPPED}${MERGE_SKIPPED:+$'\n'}  ${line}"
        ;;
    esac
  done < "$q_file"
  if [ "$MERGE_ADDED" -eq 0 ]; then
    rm -f "$tmp"
    return 0
  fi
  keeper_swap_or_clean "$tmp" "$pending"
}

_merge_locked() {
  local vault="$1" target="$2"
  local q_file
  q_file="$(_validate_quarantine_file "$vault" "$target")" || return 1
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
      MERGE_ADDED=0
      MERGE_SKIPPED=""
      _merge_pending_locked "$vault" "$q_file" || {
        printf 'error: could not merge %s into Pending.md; quarantine copy kept\n' "$b" >&2
        return 1
      }
      if [ -n "$MERGE_SKIPPED" ]; then
        printf 'Merged %s item(s) into Pending.md; kept %s because these lines are not checklist items:\n%s\n' \
          "$MERGE_ADDED" "$b" "$MERGE_SKIPPED" >&2
        return 1
      fi
      rm -f "$q_file"
      printf 'Merged %s item(s) into Pending.md and cleared %s\n' "$MERGE_ADDED" "$b"
      return 0
      ;;
  esac

  # Other files: show diff and instruction
  printf 'Manual resolution required for note %s.\n' "$b"
  cmd_diff "$vault" "$target"
}

cmd_merge() {
  local vault="$1" target="$2"
  keeper_with_lock "$vault" _merge_locked "$vault" "$target"
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
      --vault)
        [ $# -ge 2 ] || { printf 'error: --vault requires a value\n' >&2; exit 1; }
        vault="$2"; shift 2
        ;;
      *)
        if [ -z "$target" ]; then target="$1"; shift; else shift; fi
        ;;
    esac
  done

  vault="$(_resolve_vault "$vault")"

  case "$action" in
    list) cmd_list "$vault" || exit 1 ;;
    diff)
      [ -n "$target" ] || { printf 'error: diff requires <quarantine_file>\n' >&2; exit 1; }
      cmd_diff "$vault" "$target" || exit 1
      ;;
    discard)
      [ -n "$target" ] || { printf 'error: discard requires <quarantine_file>\n' >&2; exit 1; }
      cmd_discard "$vault" "$target" || exit 1
      ;;
    merge)
      [ -n "$target" ] || { printf 'error: merge requires <quarantine_file>\n' >&2; exit 1; }
      cmd_merge "$vault" "$target" || exit 1
      ;;
    *)
      printf 'unknown action: %s\n' "$action" >&2
      exit 1
      ;;
  esac
}

main "$@"
