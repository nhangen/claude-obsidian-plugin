#!/usr/bin/env bash
# vault-scan.sh — compute surfacing candidates from the vault. .md only;
# excludes .obsidian/, .trash/, .git/, .vaultkeeper-quarantine/. Never reads
# .base files (they are not .md, so the find filters exclude them).
# Requires frontmatter.sh. Sources dedup-scan.sh itself for the shared
# tokenize_slug, so clustering agrees with dedup and MOC promotion instead of
# carrying its own copy — vaultkeeper-tick.sh sources this file but not
# dedup-scan.sh. Unconditionally, on purpose: a `command -v tokenize_slug` guard
# would hand the job to whatever the caller already had in scope, which is exactly
# the drift a shared tokenizer is for. dedup-scan.sh is function definitions with
# no source-time state, so re-sourcing it costs one file read and is idempotent.
#
# scan_* report on stdout and their exit status carries no "found something"
# signal — they always return 0. `[ cond ] && printf` as a function's last
# statement otherwise leaks the failed test out as the return value, which is what
# `X="$(scan_clusters …)"` under `set -e` aborts on.
#
# Directory captured at source time; see the note in allowlist-validate.sh for
# why BASH_SOURCE alone is not enough (zsh).
_vs_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# Pre-test, not `. file || handler`: `.` is a POSIX special builtin, so under a
# `set -e` caller — which vaultkeeper-tick.sh is, and it is the only production
# sourcer — the shell exits at the failed source and the handler never runs. Same
# shape as the sibling check in allowlist-validate.sh.
if [ ! -r "${_vs_lib_dir}/dedup-scan.sh" ]; then
  printf 'vault-scan: cannot read dedup-scan.sh beside this lib (looked in "%s") — clustering has no tokenizer\n' "$_vs_lib_dir" >&2
  return 1 2>/dev/null || exit 1
fi
. "${_vs_lib_dir}/dedup-scan.sh"

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
  return 0
}

scan_unfiled() {
  local vault="$1" f
  [ -d "$vault/Inbox" ] || return 0
  while IFS= read -r f; do
    printf 'UNFILED\t%s\n' "${f#"$vault"/}"
  done < <(find "$vault/Inbox" -type f -name '*.md')
  return 0
}

scan_open_asks() {
  local vault="$1" f
  while IFS= read -r f; do
    if grep -qI '\[ask' "$f" 2>/dev/null; then
      printf 'ASK\t%s\n' "${f#"$vault"/}"
    fi
  done < <(_scan_find_md "$vault")
  return 0
}

# Cluster: per immediate subfolder, count distinct files containing each slug
# token (drop purely-numeric and single-char tokens). Emit tokens shared by
# >= threshold distinct files. No associative arrays (bash 3.2 on the macOS
# keeper host) — count via sort|uniq -c. Tokens are unique-per-file (sort -u),
# so uniq -c across files = number of distinct files sharing the token.
# One find over the whole vault, grouped by (dir, token) at the end. The previous
# shape walked directories and opened a nested process substitution per directory
# — two live fds per iteration — which exhausted the fd table under launchd and
# truncated the candidate set while still returning 0. It also lost 58% of its
# output whenever stdout was a plain pipe, with nothing on stderr. Emitting flat
# `dir<TAB>token` pairs through a single pipeline has one process substitution for
# the entire scan, so neither failure has anywhere to happen.
scan_clusters() {
  local vault="$1" threshold="$2" f dir base slug rel
  while IFS= read -r f; do
    dir="${f%/*}"
    base="${f##*/}"; base="${base%.md}"
    # Spaces are folded to the same separator before tokenizing: tokenize_slug
    # splits on `-` only, and this vault has filenames with spaces. `sort -u`
    # keeps the count "distinct files containing the token", not total occurrences.
    slug="${base// /-}"
    rel="${dir#"$vault"/}"
    tokenize_slug "$slug" | sort -u | while IFS= read -r tok; do
      [ -n "$tok" ] && printf '%s\t%s\n' "$rel" "$tok"
    done
  done < <(_scan_find_md "$vault") \
  | sort | uniq -c \
  | sed 's/^ *\([0-9][0-9]*\) /\1'"$(printf '\t')"'/' \
  | awk -F'\t' -v t="$threshold" '$1+0 >= t+0 { printf "CLUSTER\t%s\t%s\t%s\n", $2, $3, $1 }'
  return 0
}
