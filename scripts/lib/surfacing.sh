#!/usr/bin/env bash
# surfacing.sh — write the machine-owned Librarian.md digest atomically, and
# append only genuinely-new candidates to Pending.md (transition-gated against
# the prior-scan snapshot). Requires note-hash.sh + keeper-state.sh.

# surfacing_digest <vault> [status] [unreadable-count]
# `status` is stamped as `scan_status:` when non-empty. The caller passes INCOMPLETE
# when the scanners faulted: this file is the human-facing artifact and it was
# claiming a fresh full scan — timestamp AND section counts — on ticks the keeper
# itself refused to record as complete.
#
# `unreadable-count` is stamped as `paths_unreadable:`. It is separate from status on
# purpose (#51): a path the host is not allowed to read is a standing condition, not
# a fault — every readable note was still scanned — so the scan stays complete and
# says how much of the vault it could not see. A count and not the paths: they are
# absolute host paths, and this file is replicated to every host.
surfacing_digest() {
  local vault="$1" status="${2:-}" unreadable="${3:-}" lines tmp target="$1/Librarian.md" kind label
  lines="$(cat)"
  tmp="$(mktemp "$vault/.Librarian-XXXXXX")" || return 1
  {
    printf '%s\n' '<!-- MACHINE-OWNED: regenerated each vaultkeeper scan. Edits do not persist. -->'
    printf '# Librarian\n\nlast_scan: %s\n' "$(now_epoch)"
    [ -n "$status" ] && printf 'scan_status: %s\n' "$status"
    [ -n "$unreadable" ] && printf 'paths_unreadable: %s\n' "$unreadable"
    for kind in GAP UNFILED ASK CLUSTER QUARANTINE; do
      if [ "$kind" = "GAP" ]; then label="Frontmatter gaps"
      elif [ "$kind" = "UNFILED" ]; then label="Unfiled (Inbox)"
      elif [ "$kind" = "ASK" ]; then label="Open [ask] items"
      elif [ "$kind" = "CLUSTER" ]; then label="Promotable clusters"
      else label="Quarantined conflicts"
      fi
      local sel; sel="$(printf '%s\n' "$lines" | grep "^${kind}"$'\t' || true)"
      printf '\n## %s (%s)\n' "$label" "$(printf '%s' "$sel" | grep -c . || true)"
      [ -n "$sel" ] && printf '%s\n' "$sel" | cut -f2- | sed 's/^/- /'
    done
  } > "$tmp"
  mv "$tmp" "$target"
}

surfacing_pending_transition() {
  local vault="$1" cur snap new pending="$1/Pending.md"
  cur="$(sort -u)"
  if ! keeper_has_snapshot "$vault"; then
    printf '%s\n' "$cur" | keeper_write_snapshot "$vault"
    return 0
  fi
  snap="$(keeper_read_snapshot "$vault")"
  new="$(comm -23 <(printf '%s\n' "$cur") <(printf '%s\n' "$snap"))"
  if [ -n "$new" ]; then
    while IFS=$'\t' read -r kind rest; do
      [ -z "$kind" ] && continue
      printf -- '- [ ] %s: %s\n' "$kind" "$rest" >> "$pending"
    done <<<"$new"
  fi
  printf '%s\n' "$cur" | keeper_write_snapshot "$vault"
}
