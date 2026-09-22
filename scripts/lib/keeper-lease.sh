#!/usr/bin/env bash
# keeper-lease.sh — advisory lease (claim files), deterministic host election
# (pre-LLM), and quarantine-never-delete for .sync-conflict-* of keeper-owned
# files. The lease is NOT a lock; correctness rests on election + quarantine.
# Requires note-hash.sh (now_epoch).

keeper_claim_path()  { printf '%s/.keeper-claim-%s\n' "$1" "$2"; }

_keeper_claim_write_locked() {
  local vault="$1" lease="$2" host="$3" claim
  [ ! -L "$lease" ] || return 1
  mkdir -p "$lease" || return 1
  [ "$(cd "$lease" 2>/dev/null && pwd -P)" = "$lease" ] || return 1
  claim="$(keeper_claim_path "$lease" "$host")"
  now_epoch > "$claim"
}

keeper_claim_write() {
  local lease="$1" host="$2" vault
  vault="$(cd "$(dirname "$lease")" 2>/dev/null && pwd -P)" || return 1
  lease="$vault/$(basename "$lease")"
  keeper_with_lock "$vault" _keeper_claim_write_locked "$vault" "$lease" "$host"
}

keeper_live_hosts() {
  local dir="$1" max_age="${2:-}" now c host ts
  now="$(now_epoch)"
  # find, not a glob: zsh's NOMATCH aborts on an unmatched pattern and applies
  # to `for ... in <glob>` like any other expansion, so an empty claim dir would
  # take out keeper_elect with it. Matches keeper_vault_health's approach.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    host="${c##*/.keeper-claim-}"
    if [ -n "$max_age" ]; then
      ts="$(cat "$c" 2>/dev/null)"
      [ -n "$ts" ] || continue
      [ "$(( now - ts ))" -le "$max_age" ] || continue
    fi
    printf '%s\n' "$host"
  done <<EOF
$(find "$dir" -maxdepth 1 -name '.keeper-claim-*' 2>/dev/null)
EOF
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

_keeper_quarantine_conflicts_locked() {
  local vault="$1" q="$1/.vaultkeeper-quarantine" c base parent
  [ ! -L "$q" ] || return 1
  mkdir -p "$q" || return 1
  [ "$(cd "$q" 2>/dev/null && pwd -P)" = "$q" ] || return 1
  while IFS= read -r c; do
    base="$(basename "$c")"
    if printf '%s\n' "$base" | grep -qE '^Librarian\.sync-conflict-|^Pending\.sync-conflict-|^_vaultkeeper\.base\.sync-conflict-|^_vaultkeeper\.sync-conflict-.*\.base$'; then
      [ ! -L "$c" ] || { printf 'keeper_quarantine_conflicts: refusing symlink %s\n' "$c" >&2; return 1; }
      parent="$(cd "$(dirname "$c")" 2>/dev/null && pwd -P)" || return 1
      case "$parent" in "$vault"|"$vault"/*) : ;; *) return 1 ;; esac
      if ! mv "$c" "$q/$(now_epoch)-$base"; then
        printf 'keeper_quarantine_conflicts: failed to quarantine %s\n' "$c" >&2
        continue
      fi
      printf 'QUARANTINE\t%s\n' "${c#"$vault"/}"
    fi
  done < <(find "$vault" -maxdepth 2 -type f -name '*.sync-conflict-*' \
            ! -path '*/.vaultkeeper-quarantine/*' 2>/dev/null)
}

keeper_quarantine_conflicts() {
  local vault="$1" canonical
  canonical="$(cd "$vault" 2>/dev/null && pwd -P)" || return 1
  keeper_with_lock "$canonical" _keeper_quarantine_conflicts_locked "$canonical"
}
