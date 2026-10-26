#!/usr/bin/env bash
# vault-index.sh — coverage + two-stage (mtime then hash) freshness for INDEX files.
# Requires note-hash.sh to be sourced first.
#
# Also sourced into zsh, where `path`, `status`, `argv`, `pipestatus` and
# friends are special parameters (`path` is tied to PATH): never use them as
# variable names here.

index_state_file() {
  local idx="$1" dir base
  dir="$(dirname "$idx")"
  base="$(basename "$idx" .md)"
  printf '%s/.%s.state\n' "$dir" "$base"
}

# The helpers from here to vault_index_is_owned answer one note at a time.
# vault_index_plan/apply answer the same questions in batch; these remain for
# vault_index_coverage_check, the librarian, and the per-note test oracle in
# tests/vault-index-batch.sh, which pins the batch to them.
state_last_reconciled() {
  [ -f "$1" ] || return 0
  sed -n 's/^# last_reconciled://p' "$1" | head -1
}

# The key goes through ENVIRON: `awk -v` expands backslash escapes.
state_hash_for() {
  [ -f "$1" ] || return 0
  VI_KEY="$2" awk -F '\t' '$1 == ENVIRON["VI_KEY"] {print $2; exit}' "$1"
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
  find "$1" -type f -name '*.md' \
    | awk '{ sub(/.*\//, ""); if ($0 != ".md") sub(/\.md$/, ""); print }' \
    | LC_ALL=C sort | uniq -d
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

# --- Batched reconcile -------------------------------------------------------
# vault_index_plan and vault_index_apply run a fixed number of processes per
# folder, plus one note_hash per note whose mtime is newer than
# last_reconciled (every tracked note on a cold start, when there is none) or
# that a batch could not answer. They answer the same questions, with the
# same semantics, as the per-note helpers above.
#
# Paths never reach awk through `-v`, which expands backslash escapes: they go
# through ENVIRON or as data lines.

# Prefix of every "skipping" diagnostic for a name the TSV state cannot carry.
VAULT_INDEX_SKIP_MSG='vault_index_plan: skipping TSV-incompatible filename: '

# GNU stat spells its format `-c` (%Y mtime, %s size), BSD `-f` (%m, %z). A
# GNU `stat -f` "succeeds" with filesystem data (see file_mtime), so probe the
# GNU spelling and validate the answer. Cached in the current shell (a command
# substitution re-probes).
vault_index_stat_flavor_init() {
  local probe
  [ -z "${VAULT_INDEX_STAT_FLAVOR:-}" ] || return 0
  probe="$(stat -c %Y / 2>/dev/null)" || probe=""
  case "$probe" in
    ''|*[!0-9]*) VAULT_INDEX_STAT_FLAVOR=bsd ;;
    *)           VAULT_INDEX_STAT_FLAVOR=gnu ;;
  esac
}

# $1: mtime|size, $2: newline-separated paths. stdout: "<value>\t<path>" for
# each path stat could read. A path it could not read is simply absent; every
# caller treats an absent answer as "unknown" and takes the per-note path.
vault_index_stat_batch() {
  local kind="$1" list="$2" tab=$'\t' fmt
  [ -n "$list" ] || return 0
  vault_index_stat_flavor_init
  case "$VAULT_INDEX_STAT_FLAVOR" in
    gnu)
      case "$kind" in mtime) fmt="%Y${tab}%n" ;; *) fmt="%s${tab}%n" ;; esac
      printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 stat -c "$fmt" -- 2>/dev/null || : ;;
    bsd)
      case "$kind" in mtime) fmt="%m${tab}%N" ;; *) fmt="%z${tab}%N" ;; esac
      printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 stat -f "$fmt" -- 2>/dev/null || : ;;
    *) : ;;   # no usable stat: every answer is "unknown"
  esac
}

# $1: newline-separated paths. stdout: sha256 tool lines ("<hex>  <path>",
# with a leading "\" and an escaped name when the name holds "\" or a
# newline). Prefers shasum like sha256_of, and tries sha256sum when shasum is
# missing or answers nothing; a file it cannot hash is absent and falls back
# to note_hash.
vault_index_sha_batch() {
  local list="$1" out=""
  [ -n "$list" ] || return 0
  if command -v shasum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 shasum -a 256 -- 2>/dev/null)" || :
  fi
  if [ -z "$out" ] && command -v sha256sum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 sha256sum -- 2>/dev/null)" || :
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# Every *.md path under the folder, one per line. A name holding a newline
# cannot be carried line-wise: it is reported (folder-relative, with the
# newline escaped so it cannot forge a line of its own) instead of listed.
# Fails when find does, so a partial listing never reads as a smaller folder.
vault_index_find_notes() {
  local folder="$1" nl=$'\n'
  find "$folder" -type f -name '*.md' \( -name "*${nl}*" -exec sh -c '
    printf "%s" "${2#"$1"/}" | awk -v msg="$0" '"'"'BEGIN { printf "%s", msg } NR > 1 { printf "\\n" } { printf "%s", $0 } END { print "" }'"'"' >&2
  ' "$VAULT_INDEX_SKIP_MSG" "$folder" {} \; -o -print \)
}

# Remove reconcile temp files a killed apply left in the INDEX folder. Only
# this lib's own names, and only when old enough that no live apply (they run
# under the keeper lock) can still own them.
vault_index_sweep_temps() {
  find "$1" -maxdepth 1 -type f \( -name '.index-state-??????' -o -name '.index-??????' \) \
    -mmin +60 -exec rm -f {} + 2>/dev/null || :
}

# Shared awk: link matching exactly as vault_index_has_link greps for it.
#
# Every substring of an INDEX line that starts right after "[[" or "/" and
# ends right before "]]", "|", or "#" is exactly the set of strings those
# fixed-string greps can find on that line. Only names in want[] matter, so
# keep those and stop scanning past the longest one. Callers fill want[]
# (stems and their leaves), maxlen, dup[] (ambiguous leaves) and ndup (their
# count).
# shellcheck disable=SC2016  # awk source: $0 and friends are awk's, not the shell's
VAULT_INDEX_AWK_LIB='
function leaf_of(p) { sub(/.*\//, "", p); return p }
function stem_of(rel) { sub(/\.md$/, "", rel); return rel }
function want_name(stem) {
  want[stem] = 1; want[leaf_of(stem)] = 1
  if (length(stem) > maxlen) maxlen = length(stem)
}
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
      if (e < s) continue                # e == s: the empty name (a note named ".md")
      if (e - s > maxlen) break
      key = substr(line, s, e - s)
      if (key in want) { linked[key] = 1; leaflinked[key] = 1 }
    }
  }
  for (j = 1; j <= ns; j++) {
    s = S[j]
    for (k = 1; k <= ne; k++) {
      e = E[k]
      if (e < s) continue                # e == s: the empty name (a note named ".md")
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
  if (leaf in dup) return 0          # ambiguous: path form required
  # The empty leaf (a note named ".md" in a subfolder) is "ambiguous" when the
  # folder has no duplicate leaves at all: the per-note check greps the leaf
  # against the dup list with -x, and an empty list still holds one empty
  # line. Kept for parity with vault_index_has_link.
  if (leaf == "" && ndup == 0) return 0
  return (leaf in leaflinked)
}
# A state line split the way a tab-IFS `read -r key rest` splits it (the
# per-note DROP loop and carry-forward both read state that way): leading
# tabs dropped, key up to the next tab, rest without surrounding tabs.
function read_state(line,   i) {
  sub(/^\t+/, "", line)
  i = index(line, "\t")
  if (!i) { state_key = line; state_rest = ""; return }
  state_key = substr(line, 1, i - 1); state_rest = substr(line, i + 1)
  sub(/^\t+/, "", state_rest); sub(/\t+$/, "", state_rest)
}
# Keep in sync with note_hash_valid (note-hash.sh).
function hash_valid(h) { return h ~ /^[0-9]+:[0-9a-f]+$/ && length(h) - index(h, ":") == 64 }
'

# Loader for the apply-side link passes. stdin: ambiguous leaves, an empty
# line, then the added notes; then INDEX via `phase=idx`.
# shellcheck disable=SC2016  # awk source
VAULT_INDEX_AWK_ADDED='
phase == "added" && !past_dups { if ($0 == "") past_dups = 1; else { dup[$0] = 1; ndup++ } next }
phase == "added" { if ($0 != "") { A[++na] = $0; want_name(stem_of($0)) } next }
phase == "idx" { scan($0); last_line = $0; next }
'

# Plan lines: DROP/ADD/CHANGED <TAB> folder-relative path. Returns non-zero
# when the plan could not be computed, so a caller never mistakes a failed
# plan for an empty one.
vault_index_plan() {
  _vault_index_plan "$1" "$2" 0
}

# $3 = 1 also emits "DUP <TAB> leaf" for every ambiguous leaf, so apply needs
# no second walk of the folder.
_vault_index_plan() {
  local folder="$1" idx="$2" emit_dups="$3"
  local state state_in idx_in idxbase notes mtimes raw rec fn field3 field4 tab=$'\t'
  state="$(index_state_file "$idx")"
  idxbase="${idx##*/}"
  state_in=/dev/null; [ -f "$state" ] && state_in="$state"
  idx_in=/dev/null;   [ -f "$idx" ] && idx_in="$idx"

  # Recursive: a folder organized into subfolders must stay visible. A
  # single-level glob reported all 103 relocated notes as deleted and tracked
  # none of them, so the index machinery actively penalized an organized vault.
  notes="$(vault_index_find_notes "$folder")" || {
    printf 'vault_index_plan: could not list the notes under %s\n' "$folder" >&2
    return 1
  }
  mtimes="$(vault_index_stat_batch mtime "$notes")"

  raw="$(
    { [ -z "$mtimes" ] || printf '%s\n' "$mtimes"; printf '\n'; [ -z "$notes" ] || printf '%s\n' "$notes" | LC_ALL=C sort; } \
    | VI_FOLDER="$folder" VI_IDXBASE="$idxbase" VI_STATE="$state" VI_SKIP="$VAULT_INDEX_SKIP_MSG" awk "$VAULT_INDEX_AWK_LIB"'
    function owned(rel,   i) {
      for (i = 1; i <= nowned; i++)
        if (substr(rel, 1, length(ownedp[i])) == ownedp[i]) return 1
      return 0
    }
    BEGIN { prefix = ENVIRON["VI_FOLDER"] "/"; idxbase = ENVIRON["VI_IDXBASE"]; maxlen = 0 }
    # stdin: "<mtime>\t<path>" lines, an empty line, then the sorted note paths.
    phase == "notes" && !past_mtimes {
      if ($0 == "") { past_mtimes = 1; next }
      i = index($0, "\t")
      if (i && substr($0, 1, i - 1) ~ /^[0-9]+$/) mtime[substr($0, i + 1)] = substr($0, 1, i - 1)
      next
    }
    phase == "notes" {
      if ($0 == "") next
      p = $0
      rel = (substr(p, 1, length(prefix)) == prefix) ? substr(p, length(prefix) + 1) : p
      n++; P[n] = p; R[n] = rel
      noteset[rel] = 1
      leaf = leaf_of(rel); if (leaf != ".md") sub(/\.md$/, "", leaf)
      if (++leafcount[leaf] == 2) { dup[leaf] = 1; D2[++ndup] = leaf }
      # A subdirectory holding its own INDEX.md owns its notes; a parent
      # indexing them too duplicates the child (vault_index_owned_subdirs).
      if (index(rel, "/") && leaf_of(rel) == "INDEX.md") ownedp[++nowned] = substr(rel, 1, length(rel) - 8)
      want_name(stem_of(rel))
      next
    }
    phase == "state" {
      if (!have_last && substr($0, 1, 18) == "# last_reconciled:") { last = substr($0, 19); have_last = 1 }
      # Stored hash as state_hash_for reads it: fields split on every tab,
      # first matching line wins, comment lines included.
      split($0, f, "\t")
      if (!(f[1] in stored)) stored[f[1]] = f[2]
      read_state($0)
      if (state_key != "" && substr(state_key, 1, 1) != "#") K[++nk] = state_key
      next
    }
    phase == "idx" { scan($0); next }
    END {
      for (j = 1; j <= ndup; j++) printf "DUP\t%s\n", D2[j]
      # DROP: state entries whose note no longer exists at that key. A note
      # moved into a subfolder drops its stale basename key and is re-added
      # under its path key below; has_link matches the trailing segment, so
      # its existing INDEX link is not duplicated. A key not among the walked
      # notes may still be a regular file (a symlink, a non-.md name); the
      # caller settles that with `[ -f ]`, which forks nothing.
      for (j = 1; j <= nk; j++) {
        fn = K[j]
        if (fn in noteset) { if (owned(fn)) printf "DROP\t%s\n", fn }   # a child index now owns it
        else printf "MAYBE_DROP\t%s\t%s\n", fn, (owned(fn) ? "owned" : "free")
      }
      # A last_reconciled that is not a number cannot rule a note out, so
      # treat it as a cold start and check every note by hash.
      if (last != "" && last !~ /^-?[0-9]+$/) {
        printf "vault_index_plan: last_reconciled in %s is not a number; checking every note by hash\n", ENVIRON["VI_STATE"] > "/dev/stderr"
        last = ""
      }
      for (j = 1; j <= n; j++) {
        rel = R[j]
        # Skip filenames containing tabs - they corrupt TSV state.
        if (index(rel, "\t")) { gsub(/\t/, "\\t", rel); print ENVIRON["VI_SKIP"] rel > "/dev/stderr"; continue }
        if (leaf_of(rel) == idxbase) continue
        if (owned(rel)) continue
        considered++; if (!(P[j] in mtime)) unstated++
        h = (rel in stored) ? stored[rel] : ""
        if (h == "") { printf "ADD\t%s\n", rel; continue }                 # coverage gap - name-only, no content read
        if (!has_link(stem_of(rel))) { printf "ADD\t%s\n", rel; continue } # hashed but unlinked - state drifted ahead of INDEX
        if (!hash_valid(h)) { printf "CHANGED\t%s\n", rel; continue }      # malformed -> forced reconcile
        # cold start / mtime candidate / unreadable mtime -> confirm by hash
        if (last == "" || !(P[j] in mtime) || mtime[P[j]] + 0 > last + 0)
          printf "CHECK\t%s\t%s\t%s\n", rel, h, P[j]
      }
      if (unstated > 0 && unstated * 20 >= considered)
        printf "vault_index_plan: no mtime for %d of %d notes; checking those by hash, one at a time\n", unstated, considered > "/dev/stderr"
    }
  ' phase=notes - phase=state "$state_in" phase=idx "$idx_in"
  )" || {
    printf 'vault_index_plan: could not plan %s\n' "$folder" >&2
    return 1
  }

  [ -n "$raw" ] || return 0
  # Records: DUP leaf | DROP/ADD/CHANGED fn | MAYBE_DROP fn owned|free |
  # CHECK fn stored-hash note-path. Every column is non-empty, so a tab-IFS
  # read never shifts one into the next.
  while IFS="$tab" read -r rec fn field3 field4; do
    case "$rec" in
      DUP) [ "$emit_dups" != 1 ] || printf 'DUP\t%s\n' "$fn" ;;
      DROP|ADD|CHANGED) printf '%s\t%s\n' "$rec" "$fn" ;;
      MAYBE_DROP)
        if [ ! -f "$folder/$fn" ] || [ "$field3" = owned ]; then printf 'DROP\t%s\n' "$fn"; fi ;;
      CHECK)
        [ -e "$field4" ] || continue
        if [ "$(note_hash "$field4")" != "$field3" ]; then printf 'CHANGED\t%s\n' "$fn"; fi ;;
    esac
  done <<<"$raw"
  return 0
}

# Hash every ADD/CHANGED note of a plan in two batched passes (one stat for
# sizes, one sha256 run), producing exactly what note_hash would. Records:
#   HASH <TAB> fn <TAB> action <TAB> size:sha    answered by the batch
#   MISS <TAB> fn <TAB> action                   not answered; hash it singly
vault_index_hash_plan() {
  local folder="$1" plan="$2" targets sizes shas
  targets="$(printf '%s\n' "$plan" | VI_FOLDER="$folder" awk -F '\t' '
    $1 == "ADD" || $1 == "CHANGED" { printf "%s/%s\n", ENVIRON["VI_FOLDER"], $2 }')" || return 1
  [ -n "$targets" ] || return 0
  sizes="$(vault_index_stat_batch size "$targets")"
  shas="$(vault_index_sha_batch "$targets")"
  { [ -z "$sizes" ] || printf '%s\n' "$sizes"; printf '\n'
    [ -z "$shas" ] || printf '%s\n' "$shas"; printf '\n'
    printf '%s\n' "$plan"; } \
  | VI_FOLDER="$folder" awk '
    # sha256sum/shasum escape a name holding "\" or a newline and flag the
    # line with a leading "\". Undo that; anything unexpected stays unmatched
    # and falls back to note_hash.
    function unescape(s,   out, i, c, d) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c != "\\") { out = out c; continue }
        d = substr(s, ++i, 1)
        if (d == "\\") out = out "\\"
        else if (d == "n") out = out "\n"
        else if (d == "r") out = out "\r"
        else return ""
      }
      return out
    }
    BEGIN { prefix = ENVIRON["VI_FOLDER"] "/" }
    part == 0 { if ($0 == "") { part = 1; next }
                i = index($0, "\t"); if (i) size[substr($0, i + 1)] = substr($0, 1, i - 1); next }
    part == 1 { if ($0 == "") { part = 2; next }
                line = $0; esc = (substr(line, 1, 1) == "\\"); if (esc) line = substr(line, 2)
                hex = substr(line, 1, 64); sep = substr(line, 65, 2)
                if (hex !~ /^[0-9a-f]+$/ || length(hex) != 64 || (sep != "  " && sep != " *")) next
                name = substr(line, 67); if (esc) name = unescape(name)
                if (name != "") sha[name] = hex
                next }
    {
      i = index($0, "\t"); if (!i) next
      action = substr($0, 1, i - 1); fn = substr($0, i + 1)
      if (action != "ADD" && action != "CHANGED") next
      requested++
      p = prefix fn
      if ((p in size) && (p in sha) && size[p] ~ /^[0-9]+$/) printf "HASH\t%s\t%s\t%s:%s\n", fn, action, size[p], sha[p]
      else { printf "MISS\t%s\t%s\n", fn, action; missed++ }
    }
    END {
      if (missed > 0 && missed * 20 >= requested)
        printf "vault_index_apply: batch hashing answered %d of %d notes; hashing the rest one at a time\n", requested - missed, requested > "/dev/stderr"
    }'
}

# Vault-root-relative prefix ("" or "a/b/") for the links an INDEX in this
# folder gets. Obsidian resolves a slashed target against the vault root, so a
# folder-relative `sub/dir/note` would not resolve from an INDEX below the
# root, and a bare basename is ambiguous the moment two subfolders share one.
# The vault root is the nearest ancestor holding `.obsidian/`; with none
# (tests, a bare folder) links stay folder-relative, which is at least
# unambiguous.
vault_link_prefix() {
  local folder="$1" abs dir
  abs="$(cd "$folder" 2>/dev/null && pwd -P)" || return 0
  dir="$abs"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.obsidian" ]; then
      [ "$dir" = "$abs" ] || printf '%s/\n' "${abs#"$dir"/}"
      return 0
    fi
    dir="${dir%/*}"; [ -n "$dir" ] || dir=/
  done
  return 0
}

_vault_index_apply_locked() {
  local folder="$1" idx="$2"
  local state planned plan="" dups="" line rec fn action h hashed touched tmp tmp2 idx_tmp="" added=() nl=$'\n'
  state="$(index_state_file "$idx")"
  vault_index_sweep_temps "$(dirname "$idx")"
  # A failed plan must not read as "nothing to do".
  planned="$(_vault_index_plan "$folder" "$idx" 1)" || return 1
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      DUP$'\t'*) dups="$dups${line#DUP$'\t'}$nl" ;;
      *) plan="$plan$line$nl" ;;
    esac
  done <<<"$planned"

  # Extract exact filenames touched by the plan (2nd tab-field of each plan line).
  touched="$(printf '%s\n' "$plan" | cut -f2)"

  tmp="$(mktemp "${TMPDIR:-/tmp}/idxstate-XXXXXX")" || return 1
  tmp2="$(mktemp "$(dirname "$state")/.index-state-XXXXXX")" \
    || { rm -f "$tmp"; return 1; }
  # No RETURN trap: it is bash-only (zsh prints "undefined signal: RETURN" when
  # this lib is sourced into a zsh shell). There are no early returns past this
  # point, so explicit cleanup before the function's output is equivalent and
  # portable across bash and zsh.

  # Carry forward existing entries except those touched by the plan.
  if [ -f "$state" ]; then
    printf '%s\n' "$touched" | awk "$VAULT_INDEX_AWK_LIB"'
      phase == "touched" { t[$0] = 1; next }
      {
        read_state($0)
        if (state_key == "" || substr(state_key, 1, 1) == "#" || (state_key in t)) next
        printf "%s\t%s\n", state_key, state_rest
      }
    ' phase=touched - phase=state "$state" > "$tmp" \
      || { rm -f "$tmp" "$tmp2"; return 1; }
  fi
  # Apply plan: ADD/CHANGED -> (re)write current hash; DROP -> omit.
  hashed="$(vault_index_hash_plan "$folder" "$plan")" || { rm -f "$tmp" "$tmp2"; return 1; }
  if [ -n "$hashed" ]; then
    while IFS=$'\t' read -r rec fn action h; do
      [ -n "$rec" ] || continue
      [ "$rec" != MISS ] || h="$(note_hash "$folder/$fn")"
      if ! note_hash_valid "$h"; then
        printf 'vault_index_apply: skipping %s — invalid hash\n' "$fn" >&2
        continue
      fi
      printf '%s\t%s\n' "$fn" "$h" >> "$tmp"
      if [ "$action" = "ADD" ]; then added+=("$fn"); fi
    done <<<"$hashed"
  fi

  { printf '# last_reconciled:%s\n' "$(now_epoch)"; sort "$tmp"; } > "$tmp2" \
    || { rm -f "$tmp" "$tmp2"; return 1; }

  # Write the links here rather than returning them for a caller to remember.
  # Leaving this to prose is what let state run 203 notes ahead of a 12-link
  # INDEX (#30): once state claims coverage, the note never replans as an ADD.
  # Append-only — never rewrite or reorder an existing INDEX.
  local links link_prefix join_last missed
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
    link_prefix="$(vault_link_prefix "$folder")"
    # An INDEX without a final newline gets its first new link glued onto its
    # last line. That is a known defect, kept for byte parity with the
    # per-note append; the link check sees the glued line as grep would.
    join_last=0
    [ ! -s "$idx_tmp" ] || [ -z "$(tail -c 1 "$idx_tmp")" ] || join_last=1
    # One awk pass decides the links (each written link counts for the notes
    # after it, as the per-note has_link + append loop did); they are appended
    # in one write.
    links="$(
      { printf '%s' "$dups"; printf '\n'; printf '%s\n' "${added[@]}"; } \
      | VI_PREFIX="$link_prefix" VI_JOIN="$join_last" awk "$VAULT_INDEX_AWK_LIB$VAULT_INDEX_AWK_ADDED"'
        END {
          for (i = 1; i <= na; i++) {
            stem = stem_of(A[i])
            if (has_link(stem)) continue
            line = "- [[" ENVIRON["VI_PREFIX"] stem "]]"
            print line
            if (ENVIRON["VI_JOIN"] == "1" && !joined) { scan(last_line line); joined = 1 }
            scan(line)
          }
        }
      ' phase=added - phase=idx "$idx_tmp"
    )" || { rm -f "$tmp" "$tmp2" "$idx_tmp"; return 1; }
    if [ -n "$links" ]; then
      printf '%s\n' "$links" >> "$idx_tmp" \
        || {
          printf 'vault_index_apply: coverage defect in %s — links could not be written\n' "$idx" >&2
          rm -f "$tmp" "$tmp2" "$idx_tmp"
          return 1
        }
    fi
    # Verify what this run was supposed to write, against the file as written.
    # A full-folder sweep here would re-ask plan's question about every note,
    # so scope it to the set this run touched. vault_index_coverage_check is
    # the standalone full-folder assertion for a sweep.
    missed="$(
      { printf '%s' "$dups"; printf '\n'; printf '%s\n' "${added[@]}"; } \
      | awk "$VAULT_INDEX_AWK_LIB$VAULT_INDEX_AWK_ADDED"'
        END { for (i = 1; i <= na; i++) if (!has_link(stem_of(A[i]))) m++; print m + 0 }
      ' phase=added - phase=idx "$idx_tmp"
    )" || missed=""
    if [ "$missed" != 0 ]; then
      printf 'vault_index_apply: coverage defect in %s — %s link(s) could not be written\n' \
        "$idx" "${missed:-unknown}" >&2
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
