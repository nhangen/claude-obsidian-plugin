#!/usr/bin/env bash
# vault-index.sh — coverage + two-stage (mtime then hash) freshness for INDEX files.
# Requires note-hash.sh to be sourced first.

index_state_file() {
  local idx="$1" dir base
  dir="$(dirname "$idx")"
  base="$(basename "$idx" .md)"
  printf '%s/.%s.state\n' "$dir" "$base"
}

state_last_reconciled() {
  [ -f "$1" ] || return 0
  sed -n 's/^# last_reconciled://p' "$1" | head -1
}

state_hash_for() {
  [ -f "$1" ] || return 0
  awk -F '\t' -v f="$2" '$1==f {print $2; exit}' "$1"
}

vault_index_plan() {
  local folder="$1" idx="$2"
  local state last f base stored mt cur idxbase
  state="$(index_state_file "$idx")"
  last="$(state_last_reconciled "$state")"
  idxbase="$(basename "$idx")"

  # DROP: state entries whose note no longer exists.
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r fn _h; do
      [ -z "$fn" ] && continue
      case "$fn" in \#*) continue ;; esac
      [ -f "$folder/$fn" ] || printf 'DROP\t%s\n' "$fn"
    done < "$state"
  fi

  for f in "$folder"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "$idxbase" ] && continue
    stored="$(state_hash_for "$state" "$base")"
    if [ -z "$stored" ]; then
      printf 'ADD\t%s\n' "$base"          # coverage gap — name-only, no content read
      continue
    fi
    if ! note_hash_valid "$stored"; then
      printf 'CHANGED\t%s\n' "$base"       # malformed -> forced reconcile
      continue
    fi
    mt="$(file_mtime "$f")"
    if [ -z "$last" ] || [ "$mt" -gt "$last" ]; then   # candidate by mtime / cold start
      cur="$(note_hash "$f")"
      [ "$cur" != "$stored" ] && printf 'CHANGED\t%s\n' "$base"   # confirmed by hash
    fi
  done
}

vault_index_apply() {
  local folder="$1" idx="$2"
  local state plan action fn tmp added=()
  state="$(index_state_file "$idx")"
  plan="$(vault_index_plan "$folder" "$idx")"

  tmp="$(mktemp "${TMPDIR:-/tmp}/idxstate-XXXXXX")"
  # Carry forward existing entries except those touched by the plan.
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r fn h; do
      case "$fn" in ''|\#*) continue ;; esac
      if ! grep -qF -- "	$fn" <<<"$plan"; then
        printf '%s\t%s\n' "$fn" "$h" >> "$tmp"
      fi
    done < "$state"
  fi
  # Apply plan: ADD/CHANGED -> (re)write current hash; DROP -> omit.
  while IFS=$'\t' read -r action fn; do
    [ -z "$action" ] && continue
    case "$action" in
      ADD|CHANGED) printf '%s\t%s\n' "$fn" "$(note_hash "$folder/$fn")" >> "$tmp"
                   [ "$action" = "ADD" ] && added+=("$fn") ;;
      DROP) : ;;  # already excluded above
    esac
  done <<<"$plan"

  { printf '# last_reconciled:%s\n' "$(now_epoch)"; sort "$tmp"; } > "$state"
  rm -f "$tmp"
  printf '%s\n' "${added[@]:-}" | sed '/^$/d'
}
