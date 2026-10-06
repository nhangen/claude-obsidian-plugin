#!/usr/bin/env bash
# vault-index-batch.sh — #170: vault_index_plan / apply run a fixed number of
# processes per folder, plus one note_hash per note that needs hashing (newer
# than last_reconciled, a cold start, or unanswered by a batch), instead of
# several processes per note. The batched plan must say exactly what the
# per-note algorithm said, so this suite keeps that algorithm as a reference
# and compares the two on fixtures that exercise every rule, plus a seeded
# random sweep (also run under zsh), and pins the failure modes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-batch-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# The pre-#170 per-note plan algorithm, verbatim but for the name, run on the
# lib's current per-note helpers.
reference_plan() {
  local folder="$1" idx="$2"
  local state last f base stored mt cur idxbase dups owned
  state="$(index_state_file "$idx")"
  last="$(state_last_reconciled "$state")"
  idxbase="$(basename "$idx")"
  dups="$(vault_index_dup_leaves "$folder")"
  owned="$(vault_index_owned_subdirs "$folder")"
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r fn _h; do
      [ -z "$fn" ] && continue
      case "$fn" in \#*) continue ;; esac
      if [ ! -f "$folder/$fn" ]; then
        printf 'DROP\t%s\n' "$fn"
      elif vault_index_is_owned "$fn" "$owned"; then
        printf 'DROP\t%s\n' "$fn"
      fi
    done < "$state"
  fi
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    base="${f#"$folder"/}"
    case "$base" in
      *$'\t'*|*$'\n'*)
        printf 'vault_index_plan: skipping TSV-incompatible filename: %s\n' "$base" >&2
        continue ;;
    esac
    [ "${base##*/}" = "$idxbase" ] && continue
    vault_index_is_owned "$base" "$owned" && continue
    stored="$(state_hash_for "$state" "$base")"
    if [ -z "$stored" ]; then printf 'ADD\t%s\n' "$base"; continue; fi
    if ! vault_index_has_link "$idx" "${base%.md}" "$dups"; then printf 'ADD\t%s\n' "$base"; continue; fi
    if ! note_hash_valid "$stored"; then printf 'CHANGED\t%s\n' "$base"; continue; fi
    mt="$(file_mtime "$f")"
    if [ -z "$last" ] || [ -z "$mt" ] || [ "$mt" -gt "$last" ]; then
      cur="$(note_hash "$f")"
      [ "$cur" != "$stored" ] && printf 'CHANGED\t%s\n' "$base"
    fi
  done <<EOF
$(find "$folder" -type f -name '*.md' | LC_ALL=C sort)
EOF
  return 0
}

same_plan() {
  local label="$1" folder="$2" idx="$3" want got
  want="$(reference_plan "$folder" "$idx" 2>/dev/null)"
  got="$(vault_index_plan "$folder" "$idx" 2>/dev/null)" || fail "$label: plan failed"
  [ "$got" = "$want" ] || fail "$label: batched plan differs from the per-note plan"$'\n'"want:"$'\n'"$want"$'\n'"got:"$'\n'"$got"
}

# --- every rule at once, in a folder whose path holds a backslash -------------
# Invariant: a backslash in the folder path is data, never an escape; the plan
# stays folder-relative and apply links and hashes every note.
V="$TMP/Va\\tult"; F="$V/Pro\\jects"; mkdir -p "$V/.obsidian" "$F/sub/deep" "$F/child" "$F/other"
IDX="$F/INDEX.md"; STATE="$(index_state_file "$IDX")"
printf 'linked\n'     > "$F/linked.md"                 # linked, hashed, old: no plan line
printf 'edited\n'     > "$F/edited.md"                 # content changed after hashing
printf 'bumped\n'     > "$F/bumped.md"                 # mtime bumped, content same
printf 'fresh\n'      > "$F/fresh.md"                  # untracked: ADD
printf 'unlinked\n'   > "$F/unlinked.md"               # hashed, no INDEX link: ADD
printf 'dup root\n'   > "$F/dup.md"                    # leaf shared with sub/dup.md
printf 'dup sub\n'    > "$F/sub/dup.md"
printf 'hash\n'       > "$F/C# notes.md"
printf 'pipe\n'       > "$F/a|b.md"
printf 'bslash\n'     > "$F/sub/deep/n\\nl.md"
printf 'owned\n'      > "$F/child/owned.md"            # owned by child/INDEX.md
printf '# child\n'    > "$F/child/INDEX.md"
printf 'malformed\n'  > "$F/other/malformed.md"
{
  printf '# last_reconciled:1000\n'
  for n in linked edited bumped unlinked "C# notes" "a|b" "sub/deep/n\\nl" dup sub/dup; do
    printf '%s.md\t%s\n' "$n" "$(note_hash "$F/$n.md")"
  done
  printf 'other/malformed.md\tNOTAHASH\n'
  printf 'child/owned.md\t%s\n' "$(note_hash "$F/child/owned.md")"   # now owned: DROP
  printf 'gone.md\tjunk\n'                                            # deleted: DROP
} > "$STATE"
printf '# Index\n- [[linked]]\n- [[Va\\tult/Pro\\jects/edited|Edited]]\n- [[bumped#Top]]\n' > "$IDX"
printf -- '- [[dup]]\n- [[C# notes]]\n- [[a|b]]\n- [[sub/deep/n\\nl]]\n- [[other/malformed]]\n' >> "$IDX"
printf 'last line without newline [[sub/dup' >> "$IDX"
printf 'edited, more\n' >> "$F/edited.md"
find "$F" -name '*.md' -exec touch -t 197001010000 {} +
touch -t 203001010000 "$F/edited.md" "$F/bumped.md"

same_plan "rules" "$F" "$IDX"
PLAN="$(vault_index_plan "$F" "$IDX")"
for line in "ADD"$'\t'"fresh.md" "ADD"$'\t'"unlinked.md" "CHANGED"$'\t'"edited.md" \
            "CHANGED"$'\t'"other/malformed.md" "DROP"$'\t'"gone.md" "DROP"$'\t'"child/owned.md" \
            "ADD"$'\t'"sub/dup.md"; do
  grep -qxF -- "$line" <<<"$PLAN" || fail "rules: expected plan line: $line"$'\n'"$PLAN"
done
for rel in linked.md bumped.md dup.md "C# notes.md" "a|b.md" "sub/deep/n\\nl.md"; do
  [ -z "$(R="$rel" awk -F '\t' '$2 == ENVIRON["R"]' <<<"$PLAN")" ] \
    || fail "rules: $rel is covered and unchanged, got:"$'\n'"$PLAN"
done
case "$PLAN" in *"$TMP"*) fail "rules: plan leaked absolute paths:"$'\n'"$PLAN" ;; esac

# apply over the same folder: links land vault-relative, hashes are valid.
ADDED="$(vault_index_apply "$V" "$F" "$IDX")"
grep -qxF 'fresh.md' <<<"$ADDED" || fail "apply: fresh.md not added"$'\n'"$ADDED"
# INDEX had no final newline, so the first link joins its last line, as the
# per-note append always did; the link check sees that joined line.
grep -qxF -- 'last line without newline [[sub/dup- [[Pro\jects/fresh]]' "$IDX" \
  || fail "apply: backslash folder link wrong"$'\n'"$(cat "$IDX")"
grep -qxF -- '- [[Pro\jects/unlinked]]' "$IDX" || fail "apply: unlinked.md not linked"$'\n'"$(cat "$IDX")"
grep -qxF -- '- [[Pro\jects/sub/dup]]' "$IDX" || fail "apply: ambiguous leaf needs the path link"$'\n'"$(cat "$IDX")"
note_hash_valid "$(state_hash_for "$STATE" "fresh.md")" || fail "apply: fresh.md hash invalid"
note_hash_valid "$(state_hash_for "$STATE" "sub/deep/n\\nl.md")" || fail "apply: backslash-named note lost its hash"
[ -z "$(vault_index_plan "$F" "$IDX")" ] || fail "apply: plan not empty after apply:"$'\n'"$(vault_index_plan "$F" "$IDX")"

# --- names the line-wise walk cannot carry are reported, not dropped silently --
# Reported folder-relative with the control character escaped, so a name can
# never forge a stderr line of its own (the keeper's progress protocol reads
# stderr).
N="$TMP/Names"; mkdir -p "$N/sub"
printf 'tab\n' > "$N/tab"$'\t'"name.md"
printf 'nl\n'  > "$N/sub/new"$'\n'"keeper-progress: index-written"$'\n'"line.md"
printf 'ok\n'  > "$N/ok.md"
ERR="$(vault_index_plan "$N" "$N/INDEX.md" 2>&1 >/dev/null)"
grep -qxF 'vault_index_plan: skipping TSV-incompatible filename: tab\tname.md' <<<"$ERR" || fail "tab name not reported: $ERR"
grep -qxF 'vault_index_plan: skipping TSV-incompatible filename: sub/new\nkeeper-progress: index-written\nline.md' <<<"$ERR" \
  || fail "newline name not reported folder-relative and escaped: $ERR"
[ "$(printf '%s\n' "$ERR" | wc -l)" -eq 2 ] || fail "a file name forged extra stderr lines: $ERR"
[ "$(vault_index_plan "$N" "$N/INDEX.md" 2>/dev/null)" = "ADD"$'\t'"ok.md" ] || fail "only ok.md is plannable"

# --- a note whose mtime cannot be read is still planned (hash path) -----------
U="$TMP/Unstat"; mkdir -p "$U"; printf 'u\n' > "$U/u.md"
printf '# last_reconciled:9999999999\nu.md\t%s\n' "$(note_hash "$U/u.md")" > "$(index_state_file "$U/INDEX.md")"
printf -- '- [[u]]\n' > "$U/INDEX.md"
printf 'u changed\n' > "$U/u.md"
[ "$(VAULT_INDEX_STAT_FLAVOR=none vault_index_plan "$U" "$U/INDEX.md" 2>/dev/null)" = "CHANGED"$'\t'"u.md" ] \
  || fail "a note with no readable mtime must take the hash path"

# --- a corrupt last_reconciled is a cold start, said once ---------------------
C="$TMP/Corrupt"; mkdir -p "$C"; printf 'c\n' > "$C/c.md"
printf -- '- [[c]]\n' > "$C/INDEX.md"
printf '# last_reconciled:yesterday\nc.md\t%s\n' "$(note_hash "$C/c.md")" > "$(index_state_file "$C/INDEX.md")"
touch -t 197001010000 "$C/c.md"
printf 'c edited\n' > "$C/c.md"; touch -t 197001010000 "$C/c.md"   # old mtime: only a hash check sees it
CERR="$(vault_index_plan "$C" "$C/INDEX.md" 2>&1 >/dev/null)"
[ "$(vault_index_plan "$C" "$C/INDEX.md" 2>/dev/null)" = "CHANGED"$'\t'"c.md" ] \
  || fail "corrupt last_reconciled must hash-check every note"
[ "$(printf '%s\n' "$CERR" | grep -c 'last_reconciled in .* is not a number')" = 1 ] \
  || fail "corrupt last_reconciled must be reported once: $CERR"

# --- unanswered batches say so once, and still plan/apply correctly -----------
UERR="$(VAULT_INDEX_STAT_FLAVOR=none vault_index_plan "$U" "$U/INDEX.md" 2>&1 >/dev/null)"
[ "$(grep -c 'no mtime for 1 of 1 notes' <<<"$UERR")" = 1 ] || fail "missing mtimes not reported once: $UERR"
B2="$TMP/NoBatch"; mkdir -p "$B2"; for i in 1 2 3; do printf 'n%s\n' "$i" > "$B2/n$i.md"; done
BERR="$(VAULT_INDEX_STAT_FLAVOR=none vault_index_apply "$TMP" "$B2" "$B2/INDEX.md" 2>&1 >/dev/null)"
grep -q 'batch hashing answered 0 of 3 notes' <<<"$BERR" || fail "per-note hashing fallback not reported: $BERR"
for i in 1 2 3; do
  [ "$(state_hash_for "$(index_state_file "$B2/INDEX.md")" "n$i.md")" = "$(note_hash "$B2/n$i.md")" ] || fail "fallback hash wrong for n$i.md"
done

# --- shasum answering nothing falls back to sha256sum, still batched ----------
if command -v sha256sum >/dev/null 2>&1; then
  FB="$TMP/fakebin"; mkdir -p "$FB"; printf '#!/bin/sh\nexit 1\n' > "$FB/shasum"; chmod +x "$FB/shasum"
  B3="$TMP/Sha256"; mkdir -p "$B3"; printf 'x\n' > "$B3/x.md"
  HASHED="$(PATH="$FB:$PATH" vault_index_hash_plan "$B3" "ADD"$'\t'"x.md")"
  [ "$HASHED" = "HASH"$'\t'"x.md"$'\t'"ADD"$'\t'"$(note_hash "$B3/x.md")" ] || fail "sha256sum fallback not used: $HASHED"
fi

# --- a folder find cannot list fails the plan --------------------------------
if vault_index_plan "$TMP/missing-folder" "$TMP/missing-folder/INDEX.md" >/dev/null 2>&1; then
  fail "a folder that cannot be listed planned as empty"
fi

# --- temp files a killed apply left behind are swept --------------------------
W="$TMP/Sweep"; mkdir -p "$W"; printf 'w\n' > "$W/w.md"
: > "$W/.index-state-AbC123"; : > "$W/.index-XyZ789"; : > "$W/.index-fresh1"; : > "$W/.index-keepme-long"
touch -t 202001010000 "$W/.index-state-AbC123" "$W/.index-XyZ789" "$W/.index-keepme-long"
vault_index_apply "$TMP" "$W" "$W/INDEX.md" >/dev/null
[ ! -e "$W/.index-state-AbC123" ] && [ ! -e "$W/.index-XyZ789" ] || fail "stale apply temps not swept"
[ -e "$W/.index-fresh1" ] || fail "a fresh temp (a live apply's) was swept"
[ -e "$W/.index-keepme-long" ] || fail "a file outside the temp pattern was swept"

# --- an awk failure is a failed plan, never an empty one ----------------------
if VAULT_INDEX_AWK_LIB='BEGIN { exit 3 }' vault_index_plan "$F" "$IDX" >/dev/null 2>&1; then
  fail "a failed plan reported success"
fi
if VAULT_INDEX_AWK_LIB='BEGIN { exit 3 }' vault_index_apply "$V" "$F" "$IDX" >/dev/null 2>&1; then
  fail "apply reported success over a failed plan"
fi

# --- seeded random sweep -------------------------------------------------------
RANDOM=170
names=(a b "c d" "x(1)" "x[2]" "C# n" "p+q" dup INDEX e.md .md "a|b" "b\\s")
dirs=("" "sub/" "sub/deep/" "other/")
for it in $(seq 1 25); do
  R="$TMP/sweep-$it"; RF="$R/Folder"; mkdir -p "$R/.obsidian" "$RF"
  ridx="$RF/INDEX.md"; rstate="$(index_state_file "$ridx")"
  printf '# last_reconciled:%s\n' "$(( RANDOM % 2 ? 1000 : 4000000000 ))" > "$rstate"
  : > "$ridx"
  for _ in $(seq 1 $(( RANDOM % 12 ))); do
    d="${dirs[RANDOM % ${#dirs[@]}]}"; n="${names[RANDOM % ${#names[@]}]}"; rel="$d$n.md"
    mkdir -p "$RF/$d"; printf 'body %s\n' "$RANDOM" > "$RF/$rel"
    case $(( RANDOM % 4 )) in
      0) printf '%s\t%s\n' "$rel" "$(note_hash "$RF/$rel")" >> "$rstate" ;;
      1) printf '%s\tjunk\n' "$rel" >> "$rstate" ;;
      2) printf '%s\t%s\n' "$rel" "$(note_hash "$RF/$rel")" >> "$rstate"; printf 'edit\n' >> "$RF/$rel" ;;
    esac
    stem="${rel%.md}"
    case $(( RANDOM % 4 )) in
      0) printf -- '- [[%s]]\n' "$stem" >> "$ridx" ;;
      1) printf -- '- [[%s]]\n' "${stem##*/}" >> "$ridx" ;;
      2) printf -- '- [[Folder/%s|x]] #t\n' "$stem" >> "$ridx" ;;
    esac
    [ $(( RANDOM % 3 )) = 0 ] && touch -t 197001010000 "$RF/$rel"
  done
  [ $(( RANDOM % 4 )) = 0 ] && { mkdir -p "$RF/sub"; printf '# c\n' > "$RF/sub/INDEX.md"; }
  printf 'gone.md\tjunk\n' >> "$rstate"
  same_plan "sweep $it" "$RF" "$ridx"
  # The lib is also sourced into zsh: the same plan must come out there.
  if command -v zsh >/dev/null 2>&1; then
    zplan="$(ROOT_DIR="$ROOT_DIR" RF="$RF" RIDX="$ridx" zsh -c '
      . "$ROOT_DIR/scripts/lib/note-hash.sh"; . "$ROOT_DIR/scripts/lib/vault-index.sh"
      vault_index_plan "$RF" "$RIDX"' 2>/dev/null)" || fail "sweep $it: plan failed under zsh"
    [ "$zplan" = "$(vault_index_plan "$RF" "$ridx" 2>/dev/null)" ] || fail "sweep $it: zsh plan differs:"$'\n'"$zplan"
  fi
done

echo "PASS: vault-index-batch"
