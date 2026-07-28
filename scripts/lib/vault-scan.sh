#!/usr/bin/env bash
# vault-scan.sh — compute surfacing candidates from the vault. .md only;
# excludes .obsidian/, .trash/, .git/, .vaultkeeper-quarantine/. Never reads
# .base files (they are not .md, so the find filters exclude them).
# Requires frontmatter.sh. Sources dedup-scan.sh for the shared tokenize_slug so
# clustering cannot drift from dedup/MOC — vaultkeeper-tick.sh does not source it.
# Directory captured at source time; see the note in allowlist-validate.sh for
# why BASH_SOURCE alone is not enough (zsh).
_vs_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
command -v tokenize_slug >/dev/null 2>&1 || . "${_vs_lib_dir}/dedup-scan.sh"

_scan_find_md() {
  find "$1" -type f -name '*.md' \
    ! -path '*/.obsidian/*' ! -path '*/.trash/*' \
    ! -path '*/.git/*' ! -path '*/.vaultkeeper-quarantine/*' \
    ! -path '*/.vaultkeeper/*' \
    ! -name 'Librarian.md' ! -name 'Pending.md' ! -name '*.base'
}

scan_frontmatter_gaps() {
  local vault="$1" required="$2" f miss
  while IFS= read -r f; do
    miss="$(frontmatter_missing "$f" "$required" | sort | paste -sd, -)"
    [ -n "$miss" ] && printf 'GAP\t%s\t%s\n' "${f#"$vault"/}" "$miss"
  done < <(_scan_find_md "$vault")
  return 0   # reports on stdout; a failed final test must not become the status
}

scan_unfiled() {
  local vault="$1" f
  [ -d "$vault/Inbox" ] || return 0
  while IFS= read -r f; do
    printf 'UNFILED\t%s\n' "${f#"$vault"/}"
  done < <(find "$vault/Inbox" -type f -name '*.md')
  return 0   # reports on stdout; a failed final test must not become the status
}

scan_open_asks() {
  local vault="$1" f
  while IFS= read -r f; do
    if grep -qI '\[ask' "$f" 2>/dev/null; then
      printf 'ASK\t%s\n' "${f#"$vault"/}"
    fi
  done < <(_scan_find_md "$vault")
  return 0   # reports on stdout; a failed final test must not become the status
}

# Cluster: per immediate subfolder, count distinct files containing each slug
# token (drop purely-numeric and single-char tokens). Emit tokens shared by
# >= threshold distinct files. No associative arrays (bash 3.2 on the macOS
# keeper host) — count via sort|uniq -c. Tokens are unique-per-file (sort -u),
# so uniq -c across files = number of distinct files sharing the token.
scan_clusters() {
  local vault="$1" threshold="$2" dir base f tok cnt
  while IFS= read -r dir; do
    while read -r cnt tok; do
      [ -z "$cnt" ] && continue
      [ "$cnt" -ge "$threshold" ] \
        && printf 'CLUSTER\t%s\t%s\t%s\n' "${dir#"$vault"/}" "$tok" "$cnt"
    done < <(
      while IFS= read -r f; do
        base="$(basename "$f" .md)"
        # Shared tokenizer, so clustering agrees with dedup and MOC promotion
        # instead of drifting as a third inline copy (#27). Spaces are folded to
        # the same separator first — tokenize_slug splits on `-` only, and this
        # vault has filenames with spaces. `sort -u` keeps the count "distinct
        # files containing the token", not total occurrences.
        printf '%s\n' "$base" | tr ' ' '-' | while IFS= read -r slug; do
          tokenize_slug "$slug"
        done | sort -u
      done < <(find "$dir" -maxdepth 1 -type f -name '*.md') \
        | sort | uniq -c
    )
  done < <(find "$vault" -type d \
            ! -path '*/.obsidian' ! -path '*/.obsidian/*' \
            ! -path '*/.trash'    ! -path '*/.trash/*' \
            ! -path '*/.git'      ! -path '*/.git/*' \
            ! -path '*/.vaultkeeper-quarantine' ! -path '*/.vaultkeeper-quarantine/*' \
            ! -path '*/.vaultkeeper'            ! -path '*/.vaultkeeper/*')
  return 0   # reports on stdout; a failed final test must not become the status
}
