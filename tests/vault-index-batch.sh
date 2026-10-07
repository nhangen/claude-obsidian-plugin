#!/usr/bin/env bash
# vault-index-batch.sh — #170: vault_index_plan / apply run a fixed number of
# processes per folder, plus one note_hash per note that needs hashing (newer
# than last_reconciled, a cold start, or unanswered by a batch), instead of
# several processes per note. The batched plan and apply must do exactly what
# the per-note code on master did, so this suite keeps that code verbatim
# (tests/lib/vault-index-legacy.sh) as an oracle and compares plan AND apply
# against it on a fixture that exercises every rule and on a seeded sweep
# (whose plans also run under zsh). It also pins the process-count property,
# the BSD stat path, and the failure modes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-batch-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
LEGACY="$ROOT_DIR/tests/lib/vault-index-legacy.sh"

# Run a vault_index_* function as master's per-note code would.
# shellcheck source=/dev/null  # the oracle, tests/lib/vault-index-legacy.sh
legacy() ( . "$LEGACY"; "$@" )

# A state file without its last_reconciled stamp (which apply rewrites).
state_body() { [ -f "$1" ] && awk '!/^# last_reconciled:/' "$1" || :; }

# Compare batched plan and apply with the legacy code on copies of one vault.
# $1 label, $2 vault root, $3 folder path relative to the vault root.
# The legacy reader turns a non-numeric last_reconciled into per-note `[ -gt ]`
# errors; the batched one treats it as a cold start, so the legacy copy gets a
# blank stamp (its cold start) for comparison.
same_as_legacy() {
  local label="$1" v="$2" rel="$3" o="$TMP/cmp-old" n="$TMP/cmp-new" po pn ao an zp st
  rm -rf "$o" "$n"; mkdir -p "$o" "$n"
  cp -a "$v/." "$o/"; cp -a "$v/." "$n/"
  st="$(index_state_file "$o/$rel/INDEX.md")"
  if [ -f "$st" ] && grep -q '^# last_reconciled:.*[^0-9-]' "$st"; then
    awk '/^# last_reconciled:/ { print "# last_reconciled:"; next } { print }' "$st" > "$st.tmp" && mv "$st.tmp" "$st"
  fi
  [ -z "${KEEP_CMP:-}" ] || { rm -rf "$KEEP_CMP"; cp -a "$o" "$KEEP_CMP"; }
  # master's plan can end on a false `[ ] && printf` and return 1 with a
  # complete plan, so its status is not a verdict.
  po="$(legacy vault_index_plan "$o/$rel" "$o/$rel/INDEX.md" 2>/dev/null)" || :
  pn="$(vault_index_plan "$n/$rel" "$n/$rel/INDEX.md" 2>/dev/null)" || fail "$label: plan failed"
  [ "$pn" = "$po" ] || fail "$label: plan differs from master's"$'\n'"want:"$'\n'"$po"$'\n'"got:"$'\n'"$pn"
  if command -v zsh >/dev/null 2>&1; then
    zp="$(ROOT_DIR="$ROOT_DIR" F="$n/$rel" zsh -c '
      . "$ROOT_DIR/scripts/lib/note-hash.sh"; . "$ROOT_DIR/scripts/lib/vault-index.sh"
      vault_index_plan "$F" "$F/INDEX.md"' 2>/dev/null)" || fail "$label: plan failed under zsh"
    [ "$zp" = "$pn" ] || fail "$label: zsh plan differs:"$'\n'"$zp"
  fi
  ao="$(legacy vault_index_apply "$o" "$o/$rel" "$o/$rel/INDEX.md" 2>/dev/null)" || fail "$label: legacy apply failed"
  an="$(vault_index_apply "$n" "$n/$rel" "$n/$rel/INDEX.md" 2>"$TMP/apply.err")" || fail "$label: apply failed: $(cat "$TMP/apply.err")"
  [ "$an" = "$ao" ] || fail "$label: apply added differs"$'\n'"want: $ao"$'\n'"got: $an"
  [ "$(cat "$n/$rel/INDEX.md" 2>/dev/null)" = "$(cat "$o/$rel/INDEX.md" 2>/dev/null)" ] \
    || fail "$label: INDEX differs"$'\n'"$(diff "$o/$rel/INDEX.md" "$n/$rel/INDEX.md")"
  [ "$(state_body "$(index_state_file "$n/$rel/INDEX.md")")" = "$(state_body "$(index_state_file "$o/$rel/INDEX.md")")" ] \
    || fail "$label: state differs"$'\n'"$(diff <(state_body "$(index_state_file "$o/$rel/INDEX.md")") <(state_body "$(index_state_file "$n/$rel/INDEX.md")"))"
  rm -rf "$o" "$n"
}

# --- every rule at once, in a folder whose path holds a backslash -------------
# Invariant: a backslash in the folder path is data, never an escape; the plan
# stays folder-relative and apply links and hashes every note.
V="$TMP/Va\\tult"; F="$V/Pro\\jects"; mkdir -p "$V/.obsidian" "$F/sub/deep" "$F/child" "$F/other"
IDX="$F/INDEX.md"; STATE="$(index_state_file "$IDX")"
printf 'linked\n'     > "$F/linked.md"                 # linked, hashed, old: no plan line
printf 'edited\n'     > "$F/edited.md"                 # content changed after hashing
printf 'bumped\n'     > "$F/bumped.md"                 # mtime bumped, content same
printf 'equal\n'      > "$F/equal.md"                  # changed, but mtime == last_reconciled
printf 'fresh\n'      > "$F/fresh.md"                  # untracked: ADD
printf 'unlinked\n'   > "$F/unlinked.md"               # hashed, no INDEX link: ADD
printf 'lead\n'       > "$F/lead.md"                   # state line has leading tabs
printf 'short\n'      > "$F/short.md"                  # stored hash of the wrong length
printf 'dot\n'        > "$F/.md"                       # a note named exactly ".md"
printf 'dup root\n'   > "$F/dup.md"                    # leaf shared with sub/dup.md
printf 'dup sub\n'    > "$F/sub/dup.md"
printf 'hash\n'       > "$F/C# notes.md"
printf 'pipe\n'       > "$F/a|b.md"
printf 'bslash\n'     > "$F/sub/deep/n\\nl.md"
printf 'owned\n'      > "$F/child/owned.md"            # owned by child/INDEX.md
printf '# child\n'    > "$F/child/INDEX.md"
printf 'target\n'     > "$TMP/link-target.md"
ln -s "$TMP/link-target.md" "$F/child/link.md"         # a symlink note, owned by child/
printf 'plain\n'      > "$F/child/notes.txt"           # a regular non-.md file, owned by child/
printf 'malformed\n'  > "$F/other/malformed.md"
{
  printf '# last_reconciled:1000\n'
  for n in linked edited bumped equal unlinked "C# notes" "a|b" "sub/deep/n\\nl" dup sub/dup; do
    printf '%s.md\t%s\n' "$n" "$(note_hash "$F/$n.md")"
  done
  printf '\t\tlead.md\t%s\n' "$(note_hash "$F/lead.md")"
  printf 'short.md\t5:abc\n'
  printf 'other/malformed.md\tNOTAHASH\n'
  printf 'child/owned.md\t%s\n' "$(note_hash "$F/child/owned.md")"   # now owned: DROP
  printf 'child/link.md\tjunk\n'                                      # -f but not walked, owned: DROP
  printf 'child/notes.txt\tjunk\n'                                    # -f but not walked, owned: DROP
  printf 'gone.md\tjunk\n'                                            # deleted: DROP
} > "$STATE"
printf '# Index\n- [[linked]]\n- [[Va\\tult/Pro\\jects/edited|Edited]]\n- [[bumped#Top]]\n- [[equal]]\n' > "$IDX"
printf -- '- [[lead]]\n- [[short]]\n- [[dup]]\n- [[C# notes]]\n- [[a|b]]\n- [[sub/deep/n\\nl]]\n- [[other/malformed]]\n' >> "$IDX"
printf 'last line without newline [[sub/dup' >> "$IDX"
printf 'edited, more\n' >> "$F/edited.md"
printf 'equal, more\n' >> "$F/equal.md"
find "$F" -name '*.md' -exec touch -h -t 197001010000 {} +
touch -t 203001010000 "$F/edited.md" "$F/bumped.md"
EQUAL_MTIME="$(file_mtime "$F/equal.md")"
TZ=UTC touch -t 197001010016.40 "$F/equal.md"          # epoch 1000 exactly
[ "$(file_mtime "$F/equal.md")" = 1000 ] || fail "setup: equal.md mtime is $(file_mtime "$F/equal.md"), not 1000 ($EQUAL_MTIME before)"

same_as_legacy "rules" "$V" "Pro\\jects"
PLAN="$(vault_index_plan "$F" "$IDX")"
for line in "ADD"$'\t'"fresh.md" "ADD"$'\t'"unlinked.md" "ADD"$'\t'"lead.md" "ADD"$'\t'".md" \
            "CHANGED"$'\t'"edited.md" "CHANGED"$'\t'"short.md" "CHANGED"$'\t'"other/malformed.md" \
            "DROP"$'\t'"gone.md" "DROP"$'\t'"child/owned.md" "DROP"$'\t'"child/link.md" \
            "DROP"$'\t'"child/notes.txt" "ADD"$'\t'"sub/dup.md"; do
  grep -qxF -- "$line" <<<"$PLAN" || fail "rules: expected plan line: $line"$'\n'"$PLAN"
done
for rel in linked.md bumped.md equal.md dup.md "C# notes.md" "a|b.md" "sub/deep/n\\nl.md"; do
  [ -z "$(R="$rel" awk -F '\t' '$2 == ENVIRON["R"]' <<<"$PLAN")" ] \
    || fail "rules: $rel is covered and unchanged, got:"$'\n'"$PLAN"
done
case "$PLAN" in *"$TMP"*) fail "rules: plan leaked absolute paths:"$'\n'"$PLAN" ;; esac

# --- a note named ".md" in a subfolder: its leaf is the empty name ------------
# master's per-note check reads the empty leaf as ambiguous when the folder has
# no duplicate leaves (`grep -x ""` matches the empty dup list) and as a plain
# leaf otherwise, so a bare [[]] link covers it only in the second case.
for dupcase in none some; do
  E="$TMP/Empty-$dupcase"; EF="$E/Folder"; mkdir -p "$E/.obsidian" "$EF/sub"
  printf 'empty\n' > "$EF/sub/.md"
  [ "$dupcase" = none ] || { printf 'a\n' > "$EF/x.md"; printf 'b\n' > "$EF/sub/x.md"; }
  printf -- '- [[]]\n' > "$EF/INDEX.md"
  { printf '# last_reconciled:4000000000\n'; printf 'sub/.md\t%s\n' "$(note_hash "$EF/sub/.md")"; } > "$(index_state_file "$EF/INDEX.md")"
  EPLAN="$(vault_index_plan "$EF" "$EF/INDEX.md")"
  if [ "$dupcase" = none ]; then
    grep -qxF -- "ADD"$'\t'"sub/.md" <<<"$EPLAN" || fail "empty leaf, no dups: [[]] must not cover sub/.md:"$'\n'"$EPLAN"
  else
    ! grep -qF -- "sub/.md" <<<"$EPLAN" || fail "empty leaf, with dups: [[]] covers sub/.md:"$'\n'"$EPLAN"
  fi
  same_as_legacy "empty leaf, $dupcase dups" "$E" "Folder"
done

# --- the BSD stat spelling (macOS) gives the same plan -------------------------
# A shim that rejects GNU `-c` and answers `-f` with %m/%z/%N, the way BSD stat
# does. The flavor probe must pick it, and the plan must make one batched call.
REAL_STAT="$(command -v stat)"
BSD="$TMP/bsd-bin"; mkdir -p "$BSD"
cat > "$BSD/stat" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "\$STAT_SHIM_LOG"
[ "\$1" = -f ] || exit 1
fmt="\$2"; shift 2; [ "\${1-}" = -- ] && shift
rc=0
for f in "\$@"; do
  m="\$("$REAL_STAT" -c %Y -- "\$f" 2>/dev/null)" && z="\$("$REAL_STAT" -c %s -- "\$f" 2>/dev/null)" || { rc=1; continue; }
  out="\${fmt//%m/"\$m"}"; out="\${out//%z/"\$z"}"; out="\${out//%N/"\$f"}"
  printf '%s\n' "\$out"
done
exit \$rc
EOF
chmod +x "$BSD/stat"
BSDPLAN="$(unset VAULT_INDEX_STAT_FLAVOR; STAT_SHIM_LOG="$TMP/stat.log" PATH="$BSD:$PATH" vault_index_plan "$F" "$IDX")"
[ "$BSDPLAN" = "$PLAN" ] || fail "BSD stat: plan differs:"$'\n'"$BSDPLAN"
[ "$(grep -cx -- '-f' "$TMP/stat.log")" = 1 ] || fail "BSD stat: expected one batched -f call, log:"$'\n'"$(cat "$TMP/stat.log")"
grep -qx -- '-c' "$TMP/stat.log" || fail "BSD stat: the GNU spelling was never probed"

# apply over the same folder: links land vault-relative, hashes are valid.
ADDED="$(vault_index_apply "$V" "$F" "$IDX")"
grep -qxF 'fresh.md' <<<"$ADDED" || fail "apply: fresh.md not added"$'\n'"$ADDED"
# INDEX had no final newline, so the first link joins its last line, as the
# per-note append always did (a known defect kept for parity).
grep -qF -- 'last line without newline [[sub/dup- [[' "$IDX" || fail "apply: joined line missing"$'\n'"$(cat "$IDX")"
grep -qxF -- '- [[Pro\jects/unlinked]]' "$IDX" || fail "apply: unlinked.md not linked"$'\n'"$(cat "$IDX")"
grep -qxF -- '- [[Pro\jects/sub/dup]]' "$IDX" || fail "apply: ambiguous leaf needs the path link"$'\n'"$(cat "$IDX")"
note_hash_valid "$(state_hash_for "$STATE" "fresh.md")" || fail "apply: fresh.md hash invalid"
note_hash_valid "$(state_hash_for "$STATE" "sub/deep/n\\nl.md")" || fail "apply: backslash-named note lost its hash"
[ -z "$(vault_index_plan "$F" "$IDX")" ] || fail "apply: plan not empty after apply:"$'\n'"$(vault_index_plan "$F" "$IDX")"

# --- the batch answers every hash: no per-note hashing on ordinary notes ------
# With the per-note helpers broken, a cold apply of 50 notes must still store
# 50 valid hashes, which only the batched stat + sha256 path can produce.
O="$TMP/Batched"; mkdir -p "$O"; for i in $(seq 1 50); do printf 'note %s\n' "$i" > "$O/n$i.md"; done
# shellcheck disable=SC2329  # the overrides below are called from apply
(
  note_hash() { printf 'per-note-hash-called\n'; }
  file_mtime() { return 1; }
  vault_index_apply "$TMP" "$O" "$O/INDEX.md" >/dev/null 2>"$TMP/batched.err"
) || fail "batched apply failed: $(cat "$TMP/batched.err")"
[ ! -s "$TMP/batched.err" ] || fail "batched apply fell back to per-note work: $(cat "$TMP/batched.err")"
for i in $(seq 1 50); do
  [ "$(state_hash_for "$(index_state_file "$O/INDEX.md")" "n$i.md")" = "$(note_hash "$O/n$i.md")" ] || fail "n$i.md not hashed by the batch"
done

# The process count does not grow with the folder: the same calls for 10 notes
# as for 200, counted through PATH shims.
CNT="$TMP/count-bin"; mkdir -p "$CNT"
for tool in stat shasum sha256sum wc basename dirname awk find; do
  real="$(command -v "$tool")" || continue
  # shellcheck disable=SC2016  # $COUNT_LOG and $@ belong to the shim
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$COUNT_LOG"\nexec "%s" "$@"\n' "$tool" "$real" > "$CNT/$tool"
  chmod +x "$CNT/$tool"
done
calls_for() {  # calls_for <notes>: tool call counts for one cold apply
  local d="$TMP/count-$1"; mkdir -p "$d"
  for i in $(seq 1 "$1"); do printf 'c %s\n' "$i" > "$d/c$i.md"; done
  : > "$TMP/count.log"
  COUNT_LOG="$TMP/count.log" PATH="$CNT:$PATH" vault_index_apply "$TMP" "$d" "$d/INDEX.md" >/dev/null
  LC_ALL=C sort "$TMP/count.log" | uniq -c
}
SMALL="$(calls_for 10)"; LARGE="$(calls_for 200)"
[ "$SMALL" = "$LARGE" ] || fail "process count grows with the folder:"$'\n'"10 notes:"$'\n'"$SMALL"$'\n'"200 notes:"$'\n'"$LARGE"

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

# --- shasum missing or answering nothing: sha256sum, batched and per note -----
if command -v sha256sum >/dev/null 2>&1; then
  FB="$TMP/fakebin"; mkdir -p "$FB"; printf '#!/bin/sh\nexit 1\n' > "$FB/shasum"; chmod +x "$FB/shasum"
  B3="$TMP/Sha256"; mkdir -p "$B3"; printf 'x\n' > "$B3/x.md"
  WANT="$(wc -c < "$B3/x.md" | tr -d ' '):$(sha256sum "$B3/x.md" | awk '{print $1}')"
  HASHED="$(PATH="$FB:$PATH" vault_index_hash_plan "$B3" "ADD"$'\t'"x.md")"
  [ "$HASHED" = "HASH"$'\t'"x.md"$'\t'"ADD"$'\t'"$WANT" ] || fail "batch sha256sum fallback not used: $HASHED"
  [ "$(PATH="$FB:$PATH" note_hash "$B3/x.md")" = "$WANT" ] || fail "sha256_of sha256sum fallback not used"
  # shasum absent altogether (a PATH of links to every tool but shasum), so the
  # `command -v shasum` branch is skipped rather than answering nothing.
  NOSHA="$TMP/no-shasum-bin"; mkdir -p "$NOSHA"
  IFS=: read -r -a path_dirs <<<"$PATH"
  for pd in "${path_dirs[@]}"; do
    [ -d "$pd" ] || continue
    for tool in "$pd"/*; do
      [ -x "$tool" ] && [ ! -e "$NOSHA/${tool##*/}" ] && ln -s "$tool" "$NOSHA/${tool##*/}"
    done
  done
  rm -f "$NOSHA/shasum"
  (PATH="$NOSHA"; ! command -v shasum >/dev/null 2>&1) || fail "setup: shasum still on the trimmed PATH"
  HASHED="$(PATH="$NOSHA" vault_index_hash_plan "$B3" "ADD"$'\t'"x.md")"
  [ "$HASHED" = "HASH"$'\t'"x.md"$'\t'"ADD"$'\t'"$WANT" ] || fail "batch hash without shasum: $HASHED"
  [ "$(PATH="$NOSHA" note_hash "$B3/x.md")" = "$WANT" ] || fail "sha256_of without shasum: wrong hash"
  B4="$TMP/NoShasum"; mkdir -p "$B4"; for i in 1 2 3; do printf 'n%s\n' "$i" > "$B4/n$i.md"; done
  PATH="$NOSHA" vault_index_apply "$TMP" "$B4" "$B4/INDEX.md" >/dev/null || fail "apply without shasum failed"
  for i in 1 2 3; do
    [ "$(state_hash_for "$(index_state_file "$B4/INDEX.md")" "n$i.md")" = "$(note_hash "$B4/n$i.md")" ] || fail "apply without shasum: n$i.md hash wrong"
  done
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

# --- seeded random sweep: plan and apply against master's code ----------------
# A fixed LCG, not $RANDOM: bash reseeds RANDOM in subshells, so a seeded
# RANDOM does not give the same folders twice. pick N sets PICK in [0, N).
SEED="${SWEEP_SEED:-170}"
pick() { SEED=$(( (SEED * 1103515245 + 12345) % 2147483648 )); PICK=$(( (SEED / 65536) % $1 )); }
names=(a b "c d" "x(1)" "x[2]" "C# n" "p+q" dup INDEX e.md .md "" "a|b" "b\\s" "- [[a")
dirs=("" "sub/" "sub/deep/" "other/")
tails=("" "" "tail [[" "x/" "see [[sub/")
REF="$TMP/ref-mtime"; : > "$REF"; touch -t 202001010000 "$REF"; REF_EPOCH="$(file_mtime "$REF")"
for it in $(seq 1 "${SWEEP_FOLDERS:-25}"); do
  R="$TMP/sweep-$it"; RF="$R/Folder"; mkdir -p "$R/.obsidian" "$RF"
  ridx="$RF/INDEX.md"; rstate="$(index_state_file "$ridx")"
  pick 5; case $PICK in
    0) last=1000 ;; 1) last=4000000000 ;; 2) last="$REF_EPOCH" ;; 3) last=abc ;; *) last="" ;;
  esac
  printf '# last_reconciled:%s\n' "$last" > "$rstate"
  : > "$ridx"
  pick 12; for _ in $(seq 1 "$PICK"); do
    pick ${#dirs[@]}; d="${dirs[PICK]}"; pick ${#names[@]}; n="${names[PICK]}"; rel="$d$n.md"
    pick 100000; mkdir -p "$RF/$d"; printf 'body %s\n' "$PICK" > "$RF/$rel"
    lead=""; pick 5; [ "$PICK" != 0 ] || lead=$'\t'
    pick 4; case $PICK in
      0) printf '%s%s\t%s\n' "$lead" "$rel" "$(note_hash "$RF/$rel")" >> "$rstate" ;;
      1) printf '%s%s\tjunk\n' "$lead" "$rel" >> "$rstate" ;;
      2) printf '%s%s\t%s\n' "$lead" "$rel" "$(note_hash "$RF/$rel")" >> "$rstate"; printf 'edit\n' >> "$RF/$rel" ;;
    esac
    stem="${rel%.md}"
    pick 4; case $PICK in
      0) printf -- '- [[%s]]\n' "$stem" >> "$ridx" ;;
      1) printf -- '- [[%s]]\n' "${stem##*/}" >> "$ridx" ;;
      2) printf -- '- [[Folder/%s|x]] #t\n' "$stem" >> "$ridx" ;;
    esac
    pick 3; case $PICK in
      0) touch -t 197001010000 "$RF/$rel" ;;
      1) touch -t 202001010000 "$RF/$rel" ;;   # equal to last_reconciled when last is REF_EPOCH
    esac
  done
  pick 4; [ "$PICK" != 0 ] || { mkdir -p "$RF/sub"; printf '# c\n' > "$RF/sub/INDEX.md"; }
  pick ${#tails[@]}; printf '%s' "${tails[PICK]}" >> "$ridx"   # sometimes no final newline
  printf 'gone.md\tjunk\n' >> "$rstate"
  same_as_legacy "sweep $it (last=$last)" "$R" "Folder"
done

echo "PASS: vault-index-batch"
