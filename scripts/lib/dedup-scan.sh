#!/usr/bin/env bash
# dedup-scan.sh — slug tokenization + same-day duplicate detection for the vault keeper.
# Sourced by save-conversation, create-note, vault-librarian (dedup) and MOC-promotion (tokenizer).

# Splits on `-`, ` ` and `_` alike. It used to split on `-` only, and the two callers
# disagreed as a result: scan_clusters folded spaces to hyphens before calling in, but
# dedup_same_day passed the raw basename straight through — so `beta note one` and
# `beta-note-two` scored 0.00 while `beta-note-one` and `beta-note-two` scored 0.50, and
# any note saved with spaces in its name was invisible to same-day dedup against its
# hyphenated twin (#36). Folding here makes the tokenizer own its contract instead of
# each caller pre-normalising, which is what let them drift.
tokenize_slug() {
  local slug="${1%.md}" tok
  printf '%s\n' "$slug" | tr 'A-Z' 'a-z' | tr ' _-' '\n\n\n' | while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in
      *[!0-9]*) : ;;
      *) continue ;;
    esac
    [ "${#tok}" -eq 1 ] && continue
    printf '%s\n' "$tok"
  done
}

jaccard() {
  local ta tb inter uni
  ta="$(tokenize_slug "$1" | sort -u)"
  tb="$(tokenize_slug "$2" | sort -u)"
  inter="$(comm -12 <(printf '%s\n' "$ta" | grep -v '^$' | sort -u) <(printf '%s\n' "$tb" | grep -v '^$' | sort -u) | grep -c . || true)"
  uni="$(printf '%s\n%s\n' "$ta" "$tb" | grep -v '^$' | sort -u | grep -c . || true)"
  [ "$uni" -eq 0 ] && { printf '0.00\n'; return; }
  awk -v i="$inter" -v u="$uni" 'BEGIN{printf "%.2f\n", i/u}'
}

# Captured at source time — see the note in keeper-bootstrap.sh: zsh has no
# BASH_SOURCE, and its `$0` only names the sourced file while it is being read.
_ds_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || _ds_lib_dir=""

DEDUP_JACCARD_DEFAULT="0.4"

# The threshold to score against when the caller passes none. Resolved here
# rather than at each call site: the per-vault `dedup_jaccard_threshold`
# override is documented and written by setup, but every caller fell back to
# the library default instead of reading it, so a vault that set 0.0 silently
# ran at 0.4 and re-enabled the twin-note failure the check exists to prevent
# (#103). $OBSIDIAN_DEDUP_JACCARD_THRESHOLD overrides the config, for tests and
# one-off runs.
#
# An unusable value warns and falls back rather than reaching awk, where a
# non-numeric threshold compares as 0 and matches the first note it sees.
dedup_threshold() {
  local v="${OBSIDIAN_DEDUP_JACCARD_THRESHOLD:-}"
  if [ -z "$v" ] && [ -n "$_ds_lib_dir" ] && [ -f "$_ds_lib_dir/resolve-config.sh" ]; then
    . "$_ds_lib_dir/resolve-config.sh"
    v="$(obsidian_config_value dedup_jaccard_threshold || true)"
  fi
  if [ -z "$v" ]; then printf '%s\n' "$DEDUP_JACCARD_DEFAULT"; return 0; fi
  if printf '%s' "$v" | grep -qE '^(0(\.[0-9]+)?|1(\.0+)?|\.[0-9]+)$'; then
    printf '%s\n' "$v"; return 0
  fi
  printf 'dedup_same_day: unusable dedup_jaccard_threshold %s — using %s\n' \
    "$v" "$DEDUP_JACCARD_DEFAULT" >&2
  printf '%s\n' "$DEDUP_JACCARD_DEFAULT"
}

dedup_same_day() {
  local folder="$1" date="$2" slug="$3" threshold="${4:-}"
  [ -n "$threshold" ] || threshold="$(dedup_threshold)"
  local f base score best_path="" best_score="0.00"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f" .md)"; base="${base#"$date"-}"
    score="$(jaccard "$slug" "$base")"
    # Two tests, not one. Folding "beats the best so far" into the threshold
    # test seeded the comparison with best_score="0.00", so a 0.00 score could
    # never win — and `dedup_jaccard_threshold: 0.0` is documented as "always
    # prompt". That endpoint was unreachable, which went unnoticed while the
    # override reached no call site at all (#103).
    if awk -v s="$score" -v t="$threshold" 'BEGIN{exit !(s>=t)}' \
       && { [ -z "$best_path" ] || awk -v s="$score" -v b="$best_score" 'BEGIN{exit !(s>b)}'; }; then
      best_score="$score"; best_path="$f"
    fi
  done < <(find "$folder" -maxdepth 1 -type f -name "$date-*.md" 2>/dev/null)
  if [ -n "$best_path" ]; then printf '%s\t%s\n' "$best_path" "$best_score"; fi
}
