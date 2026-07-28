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
# `rel` is the note's folder-relative path stem (`note`, or `sub/dir/note`
# below the root). Match the WHOLE relative path, optionally behind a longer
# prefix, so a hand-written [[Vault/sub/dir/note]] counts as the same link an
# apply would write.
#
# `dup_leaves` (newline-separated, from vault_index_dup_leaves) lists basenames
# held by more than one note in this folder. For a basename NOT in that set, a
# bare [[note]] link is also accepted: it is unambiguous, Obsidian resolves it
# vault-wide, and an older INDEX (or one written before a note moved into a
# subfolder) links that form. For a basename that IS duplicated, only the full
# path counts — matching the leaf let the first link satisfy every namesake, so
# the rest were dropped while state still claimed them: 1001 links for 1061
# notes under Projects/Development, and permanent, since a hashed note never
# replans as an ADD.
vault_index_has_link() {
  local idx="$1" rel="$2" dups="${3-}" leaf="${2##*/}"
  [ -f "$idx" ] || return 1
  grep -qF -e "[[${rel}]]" -e "[[${rel}|" -e "[[${rel}#" \
           -e "/${rel}]]" -e "/${rel}|" -e "/${rel}#" -- "$idx" && return 0
  [ "$leaf" = "$rel" ] && return 1                       # already tried as a leaf
  grep -qxF -- "$leaf" <<<"$dups" && return 1            # ambiguous: path form required
  grep -qF -e "[[${leaf}]]" -e "[[${leaf}|" -e "[[${leaf}#" -- "$idx"
}

# Basenames held by more than one note in the folder — the set for which a bare
# [[leaf]] link is ambiguous and must not be treated as a match.
vault_index_dup_leaves() {
  find "$1" -type f -name '*.md' -exec basename {} .md \; | LC_ALL=C sort | uniq -d
}

# Link target to write for a note: vault-root-relative, because Obsidian
# resolves a slashed target against the vault root. A folder-relative
# `sub/dir/note` would not resolve from an INDEX below the root, and a bare
# basename is ambiguous the moment two subfolders share one. The vault root is
# the nearest ancestor holding `.obsidian/`; with none (tests, a bare folder)
# fall back to the folder-relative path, which is at least unambiguous.
vault_link_target() {
  local folder="$1" rel="$2" abs dir
  abs="$(cd "$folder" 2>/dev/null && pwd -P)" || { printf '%s\n' "$rel"; return; }
  dir="$abs"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.obsidian" ]; then
      [ "$dir" = "$abs" ] && printf '%s\n' "$rel" || printf '%s/%s\n' "${abs#"$dir"/}" "$rel"
      return
    fi
    dir="$(dirname "$dir")"
  done
  printf '%s\n' "$rel"
}

# Coverage assertion: state must never claim more notes than INDEX.md links.
# Returns 1 and reports on stderr when it does — that is a defect, not a normal
# state, and it means queries are reading a narrower slice than they believe.
vault_index_coverage_check() {
  local folder="$1" idx="$2" dups="${3-}" state fn unlinked=0
  state="$(index_state_file "$idx")"
  [ -f "$state" ] || return 0
  [ -n "$dups" ] || dups="$(vault_index_dup_leaves "$folder")"
  # Asserted per note, against the same predicate the writer dedups on. Counting
  # links instead let any surplus line — a duplicate, a link to a DROPped note,
  # a `*` bullet the count pattern missed — pay for a note that has none.
  while IFS=$'\t' read -r fn _h; do
    case "$fn" in ''|\#*) continue ;; esac
    vault_index_has_link "$idx" "${fn%.md}" "$dups" && continue
    printf '%s\n' "$fn"
    unlinked=$(( unlinked + 1 ))
  done < "$state"
  [ "$unlinked" -eq 0 ] && return 0
  printf 'vault_index_coverage_check: coverage defect in %s — %s tracked note(s) have no INDEX link\n' \
    "$idx" "$unlinked" >&2
  return 1
}

# Folder-relative prefixes (trailing slash) of subdirectories holding their own
# INDEX.md. Those notes belong to that index; a parent indexing them too both
# duplicates the child and dissolves the librarian's "a slice is one or two
# folders" model — Projects/Development has 11 child indexes over 1073 notes.
vault_index_owned_subdirs() {
  local folder="$1" f rel
  find "$folder" -mindepth 2 -type f -name 'INDEX.md' 2>/dev/null | while IFS= read -r f; do
    rel="${f#"$folder"/}"
    printf '%s/\n' "${rel%/INDEX.md}"
  done
}

# True when a folder-relative path sits under a subtree that owns its index.
vault_index_is_owned() {
  local rel="$1" owned="$2" prefix
  [ -n "$owned" ] || return 1
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    case "$rel" in "$prefix"*) return 0 ;; esac
  done <<EOF
$owned
EOF
  return 1
}

vault_index_plan() {
  local folder="$1" idx="$2"
  local state last f base stored mt cur idxbase dups owned
  state="$(index_state_file "$idx")"
  last="$(state_last_reconciled "$state")"
  idxbase="$(basename "$idx")"
  dups="$(vault_index_dup_leaves "$folder")"
  owned="$(vault_index_owned_subdirs "$folder")"

  # DROP: state entries whose note no longer exists at that key. A note moved
  # into a subfolder drops its stale basename key and is re-added under its
  # path key by the walk below; because has_link matches the trailing segment,
  # its existing INDEX link is not duplicated. Net effect of organizing a
  # folder is a re-key, not a loss of coverage.
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r fn _h; do
      [ -z "$fn" ] && continue
      case "$fn" in \#*) continue ;; esac
      if [ ! -f "$folder/$fn" ]; then
        printf 'DROP\t%s\n' "$fn"
      elif vault_index_is_owned "$fn" "$owned"; then
        printf 'DROP\t%s\n' "$fn"   # a child index now owns it; hand it over
      fi
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
    vault_index_is_owned "$base" "$owned" && continue
    stored="$(state_hash_for "$state" "$base")"
    if [ -z "$stored" ]; then
      printf 'ADD\t%s\n' "$base"          # coverage gap — name-only, no content read
      continue
    fi
    if ! vault_index_has_link "$idx" "${base%.md}" "$dups"; then
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
  local rel dups missed=0
  if (( ${#added[@]} )); then
    if [ ! -f "$idx" ]; then
      printf '# %s Index\n' "$(basename "$folder")" > "$idx"
    fi
    dups="$(vault_index_dup_leaves "$folder")"
    for fn in "${added[@]}"; do
      rel="${fn%.md}"
      vault_index_has_link "$idx" "$rel" "$dups" \
        || printf -- '- [[%s]]\n' "$(vault_link_target "$folder" "$rel")" >> "$idx"
    done
    # Verify what this run was supposed to write. A full-folder sweep here would
    # re-ask plan's question about every note — 1073 greps and a third
    # dup_leaves pass on a large folder, all of it already answered — so scope
    # it to the set this run touched. vault_index_coverage_check is the
    # standalone full-folder assertion for a sweep.
    for fn in "${added[@]}"; do
      vault_index_has_link "$idx" "${fn%.md}" "$dups" || missed=$(( missed + 1 ))
    done
    if [ "$missed" -gt 0 ]; then
      printf 'vault_index_apply: coverage defect in %s — %s link(s) could not be written\n' \
        "$idx" "$missed" >&2
    fi
  fi

  (( ${#added[@]} )) && printf '%s\n' "${added[@]}" || true
}
