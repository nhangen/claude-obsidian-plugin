#!/usr/bin/env bash
# dedup-scan.sh — slug tokenization + same-day duplicate detection for the vault keeper.
# Sourced by save-conversation, create-note, vault-librarian (dedup) and MOC-promotion (tokenizer).

tokenize_slug() {
  local slug="${1%.md}" tok
  printf '%s\n' "$slug" | tr 'A-Z' 'a-z' | tr '-' '\n' | while IFS= read -r tok; do
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

dedup_same_day() {
  local folder="$1" date="$2" slug="$3" threshold="${4:-0.4}"
  local f base score best_path="" best_score="0.00"
  for f in "$folder/$date"-*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .md)"; base="${base#"$date"-}"
    score="$(jaccard "$slug" "$base")"
    if awk -v s="$score" -v t="$threshold" -v b="$best_score" 'BEGIN{exit !(s>=t && s>b)}'; then
      best_score="$score"; best_path="$f"
    fi
  done
  [ -n "$best_path" ] && printf '%s\t%s\n' "$best_path" "$best_score"
}
