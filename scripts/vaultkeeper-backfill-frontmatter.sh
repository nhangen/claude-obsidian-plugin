#!/usr/bin/env bash
# vaultkeeper-backfill-frontmatter.sh — safely backfill missing frontmatter tags
# in bounded batches with dry-run mode, note body preservation, and mtime preservation.
#
# Usage:
#   scripts/vaultkeeper-backfill-frontmatter.sh [--vault <dir>] [--limit <N>] [--dry-run|--apply]

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/frontmatter.sh"
. "${ROOT}/lib/vault-scan.sh"
. "${ROOT}/lib/resolve-config.sh"

_resolve_vault() {
  local v="${1:-}"
  if [ -z "$v" ]; then
    v="$(obsidian_config_value vault_path "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}" || true)"
  fi
  [ -n "$v" ] && [ -d "$v" ] || { printf 'error: vault not found or not specified\n' >&2; exit 1; }
  cd "$v" 2>/dev/null && pwd -P
}

# Sanitize folder token to valid Obsidian tag (lowercase, kebab-case, alphanumeric+dash)
_sanitize_tag() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr ' _' '--' | tr -cd 'a-z0-9-')"
  # Strip leading and trailing dashes
  raw="${raw#"${raw%%[!-]*}"}"
  raw="${raw%"${raw##*[!-]}"}"
  printf '%s' "$raw"
}

_infer_tags() {
  local vault="$1" f="$2"
  local rel dir
  rel="${f#"$vault"/}"
  dir="$(dirname "$rel")"

  if [ "$dir" = "." ]; then
    printf 'unfiled\n'
    return 0
  fi

  case "$dir" in
    Inbox|Inbox/*)
      printf 'needs-filing\n'
      return 0
      ;;
  esac

  local tags=""
  local IFS='/'
  for part in $dir; do
    [ -n "$part" ] || continue
    local s
    s="$(_sanitize_tag "$part")"
    if [ -n "$s" ]; then
      tags="${tags:+$tags, }$s"
    fi
  done
  [ -n "$tags" ] || tags="unfiled"
  printf '%s\n' "$tags"
}

_file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

_patch_frontmatter() {
  local file="$1" tags="$2" tmp="$3"
  local has_fm=0
  if [ -f "$file" ]; then
    local first
    IFS= read -r first < "$file" || first=""
    case "$first" in
      ---*) has_fm=1 ;;
    esac
  fi

  if [ "$has_fm" = "1" ]; then
    # An unclosed frontmatter block is a malformed note, not a tags gap. Both awk
    # rewrites below assume a closing --- exists; run against an unclosed file one of
    # them re-emits the whole body as frontmatter, and the other silently drops the
    # block. The patched-file verification catches the first case, but --dry-run
    # never patches, so it printed [dry-run] for a note --apply would report [failed]
    # (#190): dry-run and apply must agree on which notes are patchable.
    local closing
    closing="$(awk 'NR>1 && $0=="---" { print NR; exit }' "$file")"
    if [ -z "$closing" ]; then
      return 1
    fi
    # Has frontmatter: check if tags: already present
    local has_tags=0
    if frontmatter_keys "$file" | grep -qxF "tags"; then
      has_tags=1
    fi

    if [ "$has_tags" = "1" ]; then
      # Replace existing tags line inside frontmatter
      awk -v tags="tags: [${tags}]" '
        NR==1 && $0 ~ /^---/ { print; in_fm=1; next }
        in_fm && $0 ~ /^---/ { in_fm=0; print; next }
        in_fm && $0 ~ /^tags:/ && !done { print tags; done=1; next }
        { print }
      ' "$file" > "$tmp"
    else
      # Insert tags line before closing ---
      awk -v tags="tags: [${tags}]" '
        NR==1 && $0 ~ /^---/ { print; in_fm=1; next }
        in_fm && $0 ~ /^---/ && !done { print tags; done=1; print; in_fm=0; next }
        { print }
      ' "$file" > "$tmp"
    fi
  else
    # No frontmatter: prepend frontmatter block preserving entire body
    {
      printf -- '---\ntags: [%s]\n---\n\n' "$tags"
      cat "$file"
    } > "$tmp"
  fi
}

main() {
  local vault="" limit=50 mode="dry-run"

  while [ $# -gt 0 ]; do
    case "$1" in
      --vault|--limit)
        [ $# -ge 2 ] || { printf 'error: %s requires a value\n' "$1" >&2; exit 1; }
        if [ "$1" = "--vault" ]; then vault="$2"; else limit="$2"; fi
        shift 2
        ;;
      --dry-run) mode="dry-run"; shift ;;
      --apply)   mode="apply";   shift ;;
      *)
        printf 'unknown argument: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  vault="$(_resolve_vault "$vault")"

  case "$limit" in
    ''|*[!0-9]*|0)
      printf 'error: --limit must be a positive integer, got "%s"\n' "$limit" >&2
      exit 1
      ;;
  esac

  printf 'vaultkeeper-backfill: scanning for notes missing tags (mode=%s, limit=%s)\n' "$mode" "$limit"

  local gaps_found=0 updated=0 failed=0
  local f rel missing tags tmp

  while IFS= read -r f; do
    missing="$(frontmatter_missing "$f" "tags")"
    if [ -n "$missing" ]; then
      gaps_found=$(( gaps_found + 1 ))
      if [ "$updated" -lt "$limit" ]; then
        rel="${f#"$vault"/}"
        tags="$(_infer_tags "$vault" "$f")"

        if [ "$mode" = "dry-run" ]; then
          # Dry-run parity (#190): stage the same patch into a temp file and run the
          # same verification as --apply, then discard it. A note that cannot be
          # patched (e.g. unclosed frontmatter) reports [failed] here too, instead of
          # promising a change that --apply would refuse to make.
          tmp="$(mktemp "$vault/.backfill-XXXXXX")" || {
            printf 'error: cannot create temp file\n' >&2
            failed=$(( failed + 1 ))
            continue
          }
          if ! _patch_frontmatter "$f" "$tags" "$tmp" \
            || [ -n "$(frontmatter_missing "$tmp" "tags")" ]; then
            rm -f "$tmp"
            printf '  [failed] %s (frontmatter could not be patched; note left unchanged)\n' "$rel" >&2
            failed=$(( failed + 1 ))
            continue
          fi
          rm -f "$tmp"
          printf '  [dry-run] %s -> tags: [%s]\n' "$rel" "$tags"
          updated=$(( updated + 1 ))
        else
          tmp="$(mktemp "$vault/.backfill-XXXXXX")" || {
            printf 'error: cannot create temp file\n' >&2
            failed=$(( failed + 1 ))
            continue
          }
          if ! _patch_frontmatter "$f" "$tags" "$tmp" \
            || [ -n "$(frontmatter_missing "$tmp" "tags")" ] \
            || ! keeper_preserve_mode "$tmp" "$f" \
            || ! touch -r "$f" "$tmp" \
            || ! keeper_swap_or_clean "$tmp" "$f"; then
            rm -f "$tmp"
            printf '  [failed] %s (frontmatter could not be patched; note left unchanged)\n' "$rel" >&2
            failed=$(( failed + 1 ))
            continue
          fi
          printf '  [applied] %s -> tags: [%s] (mtime preserved)\n' "$rel" "$tags"
          updated=$(( updated + 1 ))
        fi
      fi
    fi
  done < <(_scan_find_md "$vault")

  printf 'Summary: %s note(s) identified for update; %s total gap note(s) in vault.\n' \
    "$updated" "$gaps_found"
  if [ "$failed" -gt 0 ]; then
    printf 'vaultkeeper-backfill: %s note(s) failed and were left unchanged\n' "$failed" >&2
    return 1
  fi
}

main "$@"
