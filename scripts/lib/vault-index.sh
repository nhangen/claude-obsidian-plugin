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

# True when INDEX.md already points at this note. Fixed-string matching: note
# titles routinely contain regex metacharacters (dates, parens, brackets, +).
#
# `title` may be a folder-relative path (sub/dir/note) for a note below the
# root. A hand-written or path-form INDEX links the same note as
# [[Vault/sub/dir/note]] while an apply-written one uses [[note]], so match on
# the trailing segment and accept any path prefix. Matching only one form
# re-appends a link that is already there — observed appending duplicate
# [[TODO]] lines to an INDEX that already had [[Altamira/TODO]].
vault_index_has_link() {
  local idx="$1" title="$2" leaf="${2##*/}"
  [ -f "$idx" ] || return 1
  grep -qF -e "[[${leaf}]]" -e "[[${leaf}|" -e "[[${leaf}#" \
           -e "/${leaf}]]" -e "/${leaf}|" -e "/${leaf}#" -- "$idx"
}

# Coverage assertion: state must never claim more notes than INDEX.md links.
# Returns 1 and reports on stderr when it does — that is a defect, not a normal
# state, and it means queries are reading a narrower slice than they believe.
vault_index_coverage_check() {
  local idx="$2" state tracked linked
  state="$(index_state_file "$idx")"
  # Plain `[ -f x ] && y=...` would abort a `set -e` caller on an absent file.
  tracked=0; linked=0
  if [ -f "$state" ]; then tracked="$(grep -cv '^#' "$state" || true)"; fi
  if [ -f "$idx" ];   then linked="$(grep -cF -- '- [[' "$idx" || true)"; fi
  if [ "$linked" -lt "$tracked" ]; then
    printf 'vault_index_coverage_check: coverage defect in %s — %s links for %s tracked notes\n' \
      "$idx" "$linked" "$tracked" >&2
    return 1
  fi
  return 0
}

vault_index_plan() {
  local folder="$1" idx="$2"
  local state last f base stored mt cur idxbase
  state="$(index_state_file "$idx")"
  last="$(state_last_reconciled "$state")"
  idxbase="$(basename "$idx")"

  # DROP: state entries whose note no longer exists at that key. A note moved
  # into a subfolder drops its stale basename key and is re-added under its
  # path key by the walk below; because has_link matches the trailing segment,
  # its existing INDEX link is not duplicated. Net effect of organizing a
  # folder is a re-key, not a loss of coverage.
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r fn _h; do
      [ -z "$fn" ] && continue
      case "$fn" in \#*) continue ;; esac
      [ -f "$folder/$fn" ] || printf 'DROP\t%s\n' "$fn"
    done < "$state"
  fi

  # Recursive: a folder organized into subfolders must stay visible. A
  # single-level glob reported all 103 relocated notes as deleted and tracked
  # none of them, so the index machinery actively penalized an organized vault.
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    base="${f#"$folder"/}"           # folder-relative path, so subfolders are visible
    # Skip filenames containing tabs or newlines — they corrupt TSV state.
    case "$base" in
      *$'\t'*|*$'\n'*)
        printf 'vault_index_plan: skipping TSV-incompatible filename: %s\n' "$base" >&2
        continue ;;
    esac
    [ "${base##*/}" = "$idxbase" ] && continue
    stored="$(state_hash_for "$state" "$base")"
    if [ -z "$stored" ]; then
      printf 'ADD\t%s\n' "$base"          # coverage gap — name-only, no content read
      continue
    fi
    if ! vault_index_has_link "$idx" "${base%.md}"; then
      printf 'ADD\t%s\n' "$base"          # hashed but unlinked — state drifted ahead of INDEX
      continue
    fi
    if ! note_hash_valid "$stored"; then
      printf 'CHANGED\t%s\n' "$base"       # malformed -> forced reconcile
      continue
    fi
    mt="$(file_mtime "$f")"
    if [ -z "$last" ] || [ -z "$mt" ] || [ "$mt" -gt "$last" ]; then   # cold start / mtime candidate / unreadable->hash path
      cur="$(note_hash "$f")"
      [ "$cur" != "$stored" ] && printf 'CHANGED\t%s\n' "$base"   # confirmed by hash
    fi
  done <<EOF
$(find "$folder" -type f -name '*.md' | LC_ALL=C sort)
EOF
}

vault_index_apply() {
  local folder="$1" idx="$2"
  local state plan action fn touched tmp tmp2 added=()
  state="$(index_state_file "$idx")"
  plan="$(vault_index_plan "$folder" "$idx")"

  # Extract exact filenames touched by the plan (2nd tab-field of each plan line).
  touched="$(printf '%s\n' "$plan" | cut -f2)"

  tmp="$(mktemp "${TMPDIR:-/tmp}/idxstate-XXXXXX")" || return 1
  tmp2="$(mktemp "${TMPDIR:-/tmp}/idxstate-XXXXXX")" || { rm -f "$tmp"; return 1; }
  # No RETURN trap: it is bash-only (zsh prints "undefined signal: RETURN" when
  # this lib is sourced into a zsh shell). There are no early returns past this
  # point, so explicit cleanup before the function's output is equivalent and
  # portable across bash and zsh.

  # Carry forward existing entries except those touched by the plan.
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r fn h; do
      case "$fn" in ''|\#*) continue ;; esac
      if [ -z "$touched" ] || ! grep -qxF -- "$fn" <<<"$touched"; then
        printf '%s\t%s\n' "$fn" "$h" >> "$tmp"
      fi
    done < "$state"
  fi
  # Apply plan: ADD/CHANGED -> (re)write current hash; DROP -> omit.
  while IFS=$'\t' read -r action fn; do
    [ -z "$action" ] && continue
    case "$action" in
      ADD|CHANGED)
        local h
        h="$(note_hash "$folder/$fn")"
        if ! note_hash_valid "$h"; then
          printf 'vault_index_apply: skipping %s — invalid hash\n' "$fn" >&2
          continue
        fi
        printf '%s\t%s\n' "$fn" "$h" >> "$tmp"
        [ "$action" = "ADD" ] && added+=("$fn") ;;
      DROP) : ;;  # already excluded above
    esac
  done <<<"$plan"

  { printf '# last_reconciled:%s\n' "$(now_epoch)"; sort "$tmp"; } > "$tmp2"
  mv "$tmp2" "$state"
  rm -f "$tmp" "$tmp2"

  # Write the links here rather than returning them for a caller to remember.
  # Leaving this to prose is what let state run 203 notes ahead of a 12-link
  # INDEX (#30): once state claims coverage, the note never replans as an ADD.
  # Append-only — never rewrite or reorder an existing INDEX.
  if (( ${#added[@]} )); then
    if [ ! -f "$idx" ]; then
      printf '# %s Index\n' "$(basename "$folder")" > "$idx"
    fi
    local leaf
    for fn in "${added[@]}"; do
      # Link text is the basename, never the folder-relative path: Obsidian
      # resolves a slashed target against the VAULT root, so [[sub/dir/note]]
      # would not resolve from a folder INDEX. A bare basename resolves
      # vault-wide. has_link still matches either form, so a hand-written
      # path-form link already present is respected.
      leaf="${fn##*/}"
      vault_index_has_link "$idx" "${leaf%.md}" || printf -- '- [[%s]]\n' "${leaf%.md}" >> "$idx"
    done
  fi

  vault_index_coverage_check "$folder" "$idx" || true
  (( ${#added[@]} )) && printf '%s\n' "${added[@]}" || true
}
