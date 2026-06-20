#!/usr/bin/env bash
# keeper-lease.sh — advisory lease (claim files), deterministic host election
# (pre-LLM), and quarantine-never-delete for .sync-conflict-* of keeper-owned
# files. The lease is NOT a lock; correctness rests on election + quarantine.
# Requires note-hash.sh (now_epoch).

keeper_claim_path()  { printf '%s/.keeper-claim-%s\n' "$1" "$2"; }

keeper_claim_write() {
  mkdir -p "$1"
  now_epoch > "$(keeper_claim_path "$1" "$2")"
}

keeper_live_hosts() {
  local dir="$1" max_age="${2:-}" now c host ts
  now="$(now_epoch)"
  for c in "$dir"/.keeper-claim-*; do
    [ -e "$c" ] || continue
    host="${c##*/.keeper-claim-}"
    if [ -n "$max_age" ]; then
      ts="$(cat "$c" 2>/dev/null)"
      [ -n "$ts" ] || continue
      [ "$(( now - ts ))" -le "$max_age" ] || continue
    fi
    printf '%s\n' "$host"
  done
}

keeper_elect() {
  local dir="$1" prio_csv="${2:-}" max_age="${3:-}" hosts h
  hosts="$(keeper_live_hosts "$dir" "$max_age")"
  [ -z "$hosts" ] && return 0
  if [ -n "$prio_csv" ]; then
    local IFS=','
    for h in $prio_csv; do
      [ -z "$h" ] && continue
      if grep -qxF "$h" <<<"$hosts"; then
        printf '%s\n' "$h"
        return 0
      fi
    done
  fi
  printf '%s\n' "$hosts" | LC_ALL=C sort | head -1
}

keeper_is_owner() {
  local owner
  owner="$(keeper_elect "$1" "${3:-}" "${4:-}")"
  [ -n "$owner" ] && [ "$owner" = "$2" ]
}

keeper_quarantine_conflicts() {
  local vault="$1" q="$1/.vaultkeeper-quarantine" c base
  while IFS= read -r c; do
    base="$(basename "$c")"
    if printf '%s\n' "$base" | grep -qE '^Librarian\.sync-conflict-|^Pending\.sync-conflict-|^.*\.base\.sync-conflict-|^.*\.sync-conflict-.*\.base$'; then
      mkdir -p "$q"
      if ! mv "$c" "$q/$(now_epoch)-$base"; then
        printf 'keeper_quarantine_conflicts: failed to quarantine %s\n' "$c" >&2
        continue
      fi
      printf 'QUARANTINE\t%s\n' "${c#"$vault"/}"
    fi
  done < <(find "$vault" -maxdepth 2 -type f -name '*.sync-conflict-*' \
            ! -path '*/.vaultkeeper-quarantine/*' 2>/dev/null)
}
