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
#
# One awk pass rather than `-exec basename` per note: on a slow mount (9p) a
# fork per note was most of an INDEX reconcile's wall time (#170).
vault_index_dup_leaves() {
  find "$1" -type f -name '*.md' \
    | awk '{ sub(/.*\//, ""); if ($0 != ".md") sub(/\.md$/, ""); print }' \
    | LC_ALL=C sort | uniq -d
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

# Every note under the folder with its mtime, one "<mtime>\t<path>" line each,
# from a single find and batched stat calls. A `file_mtime` probe per note cost
# two forks per note, which on a slow mount (9p) dominated an INDEX reconcile
# (#170). GNU stat spells mtime `-c %Y`, BSD `-f %m` (see file_mtime); probe
# the flavor once. Names holding a newline cannot be carried line-wise and are
# left out, as the line-wise walk always skipped them.
vault_index_stat_notes() {
  local folder="$1" tab=$'\t' nl=$'\n' probe
  probe="$(stat -c %Y "$folder" 2>/dev/null)" || probe=""
  case "$probe" in
    ''|*[!0-9]*)
      find "$folder" -type f -name '*.md' ! -name "*${nl}*" -exec stat -f "%m${tab}%N" {} + || : ;;
    *)
      find "$folder" -type f -name '*.md' ! -name "*${nl}*" -exec stat -c "%Y${tab}%n" {} + || : ;;
  esac
}

# Plan lines: DROP/ADD/CHANGED <TAB> folder-relative path.
#
# Forks are O(1) per folder, not per note (#170): one find, batched stat, one
# awk pass over the note list, the state sidecar, and INDEX.md. The awk pass
# answers the same questions the per-note helpers do — state_hash_for,
# vault_index_has_link, vault_index_dup_leaves, vault_index_is_owned — with the
# same semantics. Only notes whose mtime is newer than last_reconciled are
# hashed, as before; that cost scales with what changed, not the folder size.
vault_index_plan() {
  local folder="$1" idx="$2"
  local state state_in idx_in idxbase action fn stored path tab=$'\t'
  state="$(index_state_file "$idx")"
  idxbase="${idx##*/}"
  state_in=/dev/null; [ -f "$state" ] && state_in="$state"
  idx_in=/dev/null;   [ -f "$idx" ] && idx_in="$idx"

  vault_index_stat_notes "$folder" | LC_ALL=C sort -t "$tab" -k2 | awk -v folder="$folder" -v idxbase="$idxbase" '
    # Same key a tab-IFS `read -r fn rest` yields: leading tabs dropped, first field.
    function read_fn(line,   i) {
      sub(/^\t+/, "", line)
      i = index(line, "\t")
      return i ? substr(line, 1, i - 1) : line
    }
    function owned(rel,   i) {
      for (i = 1; i <= nowned; i++)
        if (substr(rel, 1, length(ownedp[i])) == ownedp[i]) return 1
      return 0
    }
    function leaf_of(path) { sub(/.*\//, "", path); return path }
    # Every substring of an INDEX line that starts after "[[" or "/" and ends
    # before "]]", "|", or "#" is exactly the set of strings the fixed-string
    # greps in vault_index_has_link would find there. Only note names matter,
    # so keep those and stop scanning past the longest one.
    function scan(line,   n, i, c, nb, ns, ne, j, k, s, e, key) {
      n = length(line); nb = 0; ns = 0; ne = 0
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "[" && substr(line, i + 1, 1) == "[") B[++nb] = i + 2
        else if (c == "/") S[++ns] = i + 1
        if (c == "]" && substr(line, i + 1, 1) == "]") E[++ne] = i
        else if (c == "|" || c == "#") E[++ne] = i
      }
      for (j = 1; j <= nb; j++) {
        s = B[j]
        for (k = 1; k <= ne; k++) {
          e = E[k]
          if (e <= s) continue
          if (e - s > maxlen) break
          key = substr(line, s, e - s)
          if (key in want) { linked[key] = 1; leaflinked[key] = 1 }
        }
      }
      for (j = 1; j <= ns; j++) {
        s = S[j]
        for (k = 1; k <= ne; k++) {
          e = E[k]
          if (e <= s) continue
          if (e - s > maxlen) break
          key = substr(line, s, e - s)
          if (key in want) linked[key] = 1
        }
      }
    }
    function has_link(stem,   leaf) {
      if (stem in linked) return 1
      leaf = leaf_of(stem)
      if (leaf == stem) return 0
      if (leafcount[leaf] > 1) return 0       # ambiguous: path form required
      return (leaf in leaflinked)
    }
    function hash_valid(h,   i) {
      i = index(h, ":")
      return h ~ /^[0-9]+:[0-9a-f]+$/ && length(h) - i == 64
    }
    BEGIN { prefix = folder "/"; maxlen = 0 }
    phase == "notes" {
      i = index($0, "\t"); if (!i) next
      path = substr($0, i + 1)
      rel = (substr(path, 1, length(prefix)) == prefix) ? substr(path, length(prefix) + 1) : path
      n++; P[n] = path; R[n] = rel; M[n] = substr($0, 1, i - 1)
      noteset[rel] = 1
      leaf = leaf_of(rel); if (leaf != ".md") sub(/\.md$/, "", leaf)
      leafcount[leaf]++
      if (index(rel, "/") && leaf_of(rel) == "INDEX.md") ownedp[++nowned] = substr(rel, 1, length(rel) - 8)
      stem = rel; sub(/\.md$/, "", stem)
      want[stem] = 1; want[leaf_of(stem)] = 1
      if (length(stem) > maxlen) maxlen = length(stem)
      next
    }
    phase == "state" {
      if (!have_last && substr($0, 1, 18) == "# last_reconciled:") { last = substr($0, 19); have_last = 1 }
      split($0, f, "\t")
      if (!(f[1] in stored)) stored[f[1]] = f[2]
      fn = read_fn($0)
      if (fn != "" && substr(fn, 1, 1) != "#") D[++nd] = fn
      next
    }
    phase == "idx" { scan($0); next }
    END {
      # DROP: state entries whose note no longer exists at that key. A note
      # moved into a subfolder drops its stale basename key and is re-added
      # under its path key below; has_link matches the trailing segment, so
      # its existing INDEX link is not duplicated. A key not among the walked
      # notes may still be a regular file (a symlink, a non-.md name); the
      # caller settles that with `[ -f ]`, which forks nothing.
      for (j = 1; j <= nd; j++) {
        fn = D[j]
        if (fn in noteset) { if (owned(fn)) printf "DROP\t%s\n", fn }   # a child index now owns it
        else printf "MAYBE_DROP\t%s\t%d\n", fn, owned(fn)
      }
      numeric_last = (last ~ /^-?[0-9]+$/)
      for (j = 1; j <= n; j++) {
        rel = R[j]
        # Skip filenames containing tabs - they corrupt TSV state.
        if (index(rel, "\t")) {
          printf "vault_index_plan: skipping TSV-incompatible filename: %s\n", rel > "/dev/stderr"
          continue
        }
        if (leaf_of(rel) == idxbase) continue
        if (owned(rel)) continue
        h = (rel in stored) ? stored[rel] : ""
        if (h == "") { printf "ADD\t%s\n", rel; continue }          # coverage gap - name-only, no content read
        stem = rel; sub(/\.md$/, "", stem)
        if (!has_link(stem)) { printf "ADD\t%s\n", rel; continue }  # hashed but unlinked - state drifted ahead of INDEX
        if (!hash_valid(h)) { printf "CHANGED\t%s\n", rel; continue } # malformed -> forced reconcile
        # cold start / mtime candidate -> confirm by hash in the caller
        if (last == "" || (numeric_last && M[j] + 0 > last + 0)) printf "CHECK\t%s\t%s\t%s\n", rel, h, P[j]
      }
    }
  ' phase=notes - phase=state "$state_in" phase=idx "$idx_in" \
  | while IFS="$tab" read -r action fn stored path; do
      case "$action" in
        DROP|ADD|CHANGED) printf '%s\t%s\n' "$action" "$fn" ;;
        MAYBE_DROP)
          if [ ! -f "$folder/$fn" ] || [ "$stored" = 1 ]; then printf 'DROP\t%s\n' "$fn"; fi ;;
        CHECK)
          [ -e "$path" ] || continue
          if [ "$(note_hash "$path")" != "$stored" ]; then printf 'CHANGED\t%s\n' "$fn"; fi ;;
      esac
    done
}

_vault_index_apply_locked() {
  local folder="$1" idx="$2"
  local state plan action fn touched tmp tmp2 idx_tmp="" added=()
  state="$(index_state_file "$idx")"
  plan="$(vault_index_plan "$folder" "$idx")"

  # Extract exact filenames touched by the plan (2nd tab-field of each plan line).
  touched="$(printf '%s\n' "$plan" | cut -f2)"

  tmp="$(mktemp "${TMPDIR:-/tmp}/idxstate-XXXXXX")" || return 1
  tmp2="$(mktemp "$(dirname "$state")/.index-state-XXXXXX")" \
    || { rm -f "$tmp"; return 1; }
  # No RETURN trap: it is bash-only (zsh prints "undefined signal: RETURN" when
  # this lib is sourced into a zsh shell). There are no early returns past this
  # point, so explicit cleanup before the function's output is equivalent and
  # portable across bash and zsh.

  # Carry forward existing entries except those touched by the plan. One awk
  # pass: a `grep` per state line was a fork per tracked note (#170). Fields
  # are split the way a tab-IFS `read -r fn h` splits them.
  if [ -f "$state" ]; then
    printf '%s\n' "$touched" | awk '
      phase == "touched" { t[$0] = 1; next }
      {
        line = $0; sub(/^\t+/, "", line)
        i = index(line, "\t")
        if (i) { fn = substr(line, 1, i - 1); h = substr(line, i + 1); sub(/^\t+/, "", h); sub(/\t+$/, "", h) }
        else { fn = line; h = "" }
        if (fn == "" || substr(fn, 1, 1) == "#" || (fn in t)) next
        printf "%s\t%s\n", fn, h
      }
    ' phase=touched - phase=state "$state" > "$tmp" \
      || { rm -f "$tmp" "$tmp2"; return 1; }
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

  { printf '# last_reconciled:%s\n' "$(now_epoch)"; sort "$tmp"; } > "$tmp2" \
    || { rm -f "$tmp" "$tmp2"; return 1; }

  # Write the links here rather than returning them for a caller to remember.
  # Leaving this to prose is what let state run 203 notes ahead of a 12-link
  # INDEX (#30): once state claims coverage, the note never replans as an ADD.
  # Append-only — never rewrite or reorder an existing INDEX.
  local rel dups missed=0
  if (( ${#added[@]} )); then
    if [ -e "$idx" ] && [ ! -w "$idx" ]; then
      printf 'vault_index_apply: coverage defect in %s — INDEX is not writable\n' "$idx" >&2
      rm -f "$tmp" "$tmp2"
      return 1
    fi
    idx_tmp="$(mktemp "$(dirname "$idx")/.index-XXXXXX")" \
      || { rm -f "$tmp" "$tmp2"; return 1; }
    if [ -f "$idx" ]; then
      cp "$idx" "$idx_tmp" || { rm -f "$tmp" "$tmp2" "$idx_tmp"; return 1; }
    else
      printf '# %s Index\n' "$(basename "$folder")" > "$idx_tmp" \
        || { rm -f "$tmp" "$tmp2" "$idx_tmp"; return 1; }
    fi
    dups="$(vault_index_dup_leaves "$folder")"
    for fn in "${added[@]}"; do
      rel="${fn%.md}"
      if ! vault_index_has_link "$idx_tmp" "$rel" "$dups"; then
        printf -- '- [[%s]]\n' "$(vault_link_target "$folder" "$rel")" >> "$idx_tmp" \
          || {
            printf 'vault_index_apply: coverage defect in %s — link for %s could not be written\n' \
              "$idx" "$fn" >&2
            rm -f "$tmp" "$tmp2" "$idx_tmp"
            return 1
          }
      fi
    done
    # Verify what this run was supposed to write. A full-folder sweep here would
    # re-ask plan's question about every note — 1073 greps and a third
    # dup_leaves pass on a large folder, all of it already answered — so scope
    # it to the set this run touched. vault_index_coverage_check is the
    # standalone full-folder assertion for a sweep.
    for fn in "${added[@]}"; do
      vault_index_has_link "$idx_tmp" "${fn%.md}" "$dups" || missed=$(( missed + 1 ))
    done
    if [ "$missed" -gt 0 ]; then
      printf 'vault_index_apply: coverage defect in %s — %s link(s) could not be written\n' \
        "$idx" "$missed" >&2
      rm -f "$tmp" "$tmp2" "$idx_tmp"
      return 1
    fi
    keeper_swap_or_clean "$idx_tmp" "$idx" || { rm -f "$tmp" "$tmp2"; return 1; }
  fi

  keeper_fault before_index_state || { rm -f "$tmp" "$tmp2"; return 91; }
  keeper_swap_or_clean "$tmp2" "$state" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  keeper_fault after_index_state || return 91

  (( ${#added[@]} )) && printf '%s\n' "${added[@]}" || true
}

_vault_index_apply_guarded() {
  local folder="$1" idx="$2"
  [ ! -L "$idx" ] || { printf 'vault_index_apply: refusing symlink INDEX: %s\n' "$idx" >&2; return 1; }
  [ ! -e "$idx" ] || [ -f "$idx" ] \
    || { printf 'vault_index_apply: INDEX is not a regular file: %s\n' "$idx" >&2; return 1; }
  [ ! -L "$(index_state_file "$idx")" ] \
    || { printf 'vault_index_apply: refusing symlink state: %s\n' "$(index_state_file "$idx")" >&2; return 1; }
  _vault_index_apply_locked "$folder" "$idx"
}

vault_index_apply_held() {
  local vault="$1" folder="$2" idx="$3" canonical_vault canonical idx_parent canonical_idx_parent canonical_idx
  canonical_vault="$(cd "$vault" 2>/dev/null && pwd -P)" || return 1
  canonical="$(cd "$folder" 2>/dev/null && pwd -P)" || return 1
  case "$canonical" in
    "$canonical_vault"|"$canonical_vault"/*) : ;;
    *) printf 'vault_index_apply: indexed folder is outside the configured vault: %s\n' "$folder" >&2; return 1 ;;
  esac
  idx_parent="$(dirname "$idx")"
  canonical_idx_parent="$(cd "$idx_parent" 2>/dev/null && pwd -P)" || return 1
  if [ "$canonical_idx_parent" != "$canonical" ]; then
    printf 'vault_index_apply: INDEX must be inside its indexed folder: %s\n' "$idx" >&2
    return 1
  fi
  canonical_idx="$canonical/$(basename "$idx")"
  _vault_index_apply_guarded "$canonical" "$canonical_idx"
}

vault_index_apply() {
  local vault="$1" canonical_vault
  canonical_vault="$(cd "$vault" 2>/dev/null && pwd -P)" || return 1
  shift
  keeper_with_lock "$canonical_vault" vault_index_apply_held "$canonical_vault" "$@"
}
