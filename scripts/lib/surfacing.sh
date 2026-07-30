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
  keeper_swap_or_clean "$tmp" "$target"
}

# surfacing_pending_append <vault>
# Append rows to Pending.md without touching the prior-scan snapshot. For rows whose
# side effect already happened and cannot be re-derived (#58).
#
# The four scanners re-derive their rows every tick, so withholding them on a faulted
# tick loses nothing — the next healthy tick emits them again. QUARANTINE is not like
# that: the row is a receipt for an irreversible `mv`, emitted exactly once, and the
# file it names is excluded from every later walk, so a row dropped here is dropped
# permanently. The user loses the `- [ ] QUARANTINE: …` line telling them a sync
# conflict needs merging. The file is safely in .vaultkeeper-quarantine either way.
#
# Append-only is what makes this safe next to the transition gate: the snapshot is
# left alone, and because the row can never be re-derived, the next healthy tick's
# `comm -23` cannot see it as new and re-append it.
surfacing_pending_append() {
  local vault="$1" pending="$1/Pending.md" line out payload
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    payload="$(printf '%s' "$line" | sed 's/'$'\t''/: /')"
    out="- [ ] ${payload}"
    # Idempotent against what is already there — and against the box being TICKED
    # (#37). Comparing whole lines missed `- [x] …`, so a candidate that dropped out
    # of one scan and came back later got a fresh unchecked line appended next to the
    # one the user had already ticked. Pending.md is hand-edited and
    # Syncthing-replicated, which makes this the one path where a bug touches notes a
    # person is working in. Compare the payload with the checkbox stripped, so any box
    # state counts as present.
    if [ -f "$pending" ] \
      && sed -n 's/^- \[[^]]*\] //p' "$pending" | grep -qxF -- "$payload"; then
      continue
    fi
    printf '%s\n' "$out" >> "$pending"
  done
  return 0
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
  # Through the same deduping appender as the irreversible-row path. The snapshot is
  # written *after* the append, so a failed snapshot swap leaves the append committed
  # and the gate un-advanced: every later tick sees the same rows as new. That order is
  # the right one — it fails toward a duplicate line rather than a lost one — but with
  # a plain `>>` it grew Pending.md without bound, three lines a tick, in a file the
  # user hand-edits and Syncthing replicates (#43). Deduping makes the stuck state
  # idempotent instead; the stalled keeper still shows up through the staleness banner.
  if [ -n "$new" ]; then
    printf '%s\n' "$new" | surfacing_pending_append "$vault"
  fi
  printf '%s\n' "$cur" | keeper_write_snapshot "$vault"
}
