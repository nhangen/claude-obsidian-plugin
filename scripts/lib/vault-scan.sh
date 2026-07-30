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

# A record's path field is vault-relative by contract, and every scanner used to
# strip with `${p#"$vault"/}` inline. That trailing slash is part of the pattern,
# so it cannot match when the path *is* the vault — a `.md` file directly in the
# vault root produced `CLUSTER<TAB>/Users/<name>/Documents/Obsidian<TAB>…`, and
# that row lands in Librarian.md, which Syncthing replicates to every host. The
# local username left the machine (#56).
_scan_rel() {
  local vault="$1" rel="$2"
  rel="${rel#"$vault"}"
  rel="${rel#/}"
  [ -n "$rel" ] || rel="."
  # find is rooted at the vault, so a path that did not strip is unreachable. If
  # it ever happens, the row must still not carry an absolute host path into a
  # synced file — losing the directory beats leaking the home directory.
  case "$rel" in
    /*) rel="${rel##*/}" ;;
  esac
  printf '%s' "$rel"
}

# Two different things used to arrive on the scanners' stderr and the tick could
# only see "some bytes", so it treated both as a fault (#51):
#
#   unreadable — one `chmod 000` directory, an iCloud path macOS TCC refuses, a
#     stale network mount. `find` prints `Permission denied` and walks on. Every
#     readable note WAS scanned, and no tick can ever fix the path, so treating it
#     as a fault made the gate latch: INCOMPLETE forever, last_scan never recorded,
#     no recovery. Counted here and reported as a count, not a fault.
#   truncated — the scan stopped early: `find` killed by a signal, or dying of fd
#     or memory exhaustion. The candidate set is short and nothing said so. This is
#     the half stderr missed entirely, because a scanner killed by a signal prints
#     nothing at all.
#
# So the walk gets a real status instead of a diagnostic channel. Deliberately a
# noise *denylist* rather than a fatal-pattern allowlist: a too-narrow allowlist
# fails silent, which is the bug class this is removing, hand-rebuilt. A too-narrow
# denylist merely reports a benign line as a fault — loud, and recoverable.
#
# The unreadable channel is a file because the walk runs inside a pipeline (and,
# for the scanners, inside a process substitution), so a variable set here would be
# set in a subshell and lost. The caller opts in by creating it; a caller that does
# not gets the old behaviour — every line on stderr — which is loud, not silent.
#
# Returns non-zero when it could not record the line, so the caller can fall back
# to stderr. Swallowing it here instead would make an unset collector mean "drop
# these silently" — the exact silence this classification exists to remove, just
# relocated.
_scan_note_unreadable() {
  [ -n "${KEEPER_SCAN_UNREADABLE_FILE:-}" ] || return 1
  printf '%s\n' "$1" >> "$KEEPER_SCAN_UNREADABLE_FILE" 2>/dev/null || return 1
  return 0
}

_scan_walk() {
  local root="$1"; shift
  local err rc=0 line
  err="$(mktemp "${TMPDIR:-/tmp}/kbwalk-XXXXXX" 2>/dev/null)" || err=""
  if [ -z "$err" ]; then
    # No buffer means no classification, and silently reclassifying everything as
    # benign is the failure this function exists to prevent. Say so and let the
    # walk's own stderr through untouched.
    printf 'vault-scan: cannot buffer find stderr (mktemp failed); walk of %s is not verifiable\n' "$root" >&2
    find "$root" "$@" || true
    return 0
  fi
  # `|| rc=$?` and not a bare call: an unreadable directory makes find exit 1, and
  # the only production caller runs under `set -e`, so a bare call would kill this
  # subshell right here — skipping the classification below, which is the whole
  # point of the function.
  find "$root" "$@" 2>"$err" || rc=$?
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *'Permission denied'*|*'Operation not permitted'*)
        _scan_note_unreadable "$line" || printf '%s\n' "$line" >&2
        ;;
      *) printf '%s\n' "$line" >&2 ;;
    esac
  done < "$err"
  rm -f "$err" 2>/dev/null || true
  # 128+N is "killed by signal N", which is the shape of a walk that stopped
  # partway. find's plain exit 1 covers the unreadable-path case too, so it is not
  # evidence of truncation on its own — the lines above already spoke for that.
  if [ "$rc" -ge 128 ]; then
    printf 'vault-scan: the walk of %s was killed (exit %s) — the candidate set is truncated\n' "$root" "$rc" >&2
  fi
  return 0
}

_scan_find_md() {
  _scan_walk "$1" -type f -name '*.md' \
    ! -path '*/.obsidian/*' ! -path '*/.trash/*' \
    ! -path '*/.git/*' ! -path '*/.vaultkeeper-quarantine/*' \
    ! -path '*/.vaultkeeper/*' \
    ! -name 'Librarian.md' ! -name 'Pending.md' ! -name '*.base'
}

scan_frontmatter_gaps() {
  local vault="$1" required="$2" f miss
  while IFS= read -r f; do
    miss="$(frontmatter_missing "$f" "$required" | sort | paste -sd, -)"
    [ -n "$miss" ] && printf 'GAP\t%s\t%s\n' "$(_scan_rel "$vault" "$f")" "$miss"
  done < <(_scan_find_md "$vault")
  return 0
}

scan_unfiled() {
  local vault="$1" f
  [ -d "$vault/Inbox" ] || return 0
  while IFS= read -r f; do
    printf 'UNFILED\t%s\n' "$(_scan_rel "$vault" "$f")"
  done < <(_scan_walk "$vault/Inbox" -type f -name '*.md')
  return 0
}

scan_open_asks() {
  local vault="$1" f
  while IFS= read -r f; do
    if grep -qI '\[ask' "$f" 2>/dev/null; then
      printf 'ASK\t%s\n' "$(_scan_rel "$vault" "$f")"
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
# truncated the candidate set while still returning 0. How much it dropped tracked
# whatever fd headroom happened to exist at runtime: the same frozen 569-directory
# vault came back with 503 clusters on an idle host and 211 under load, identical
# through a pipe and through a file redirect, and with nothing on stderr in either
# case. Emitting flat `dir<TAB>token` pairs through a single pipeline leaves one
# process substitution for the whole scan, so there is no headroom to run out of.
scan_clusters() {
  local vault="$1" threshold="$2" f dir base slug rel
  # The awk gate below coerces a non-numeric threshold to 0, so `""` or `"abc"`
  # returned every token in the vault as a cluster — silently, filling Librarian.md
  # with noise. `"3.7"` returned a partial answer for the same reason. The `[ "$cnt"
  # -ge "$threshold" ]` shape this replaced errored loudly instead, and loud is the
  # direction this codebase went in #49. Production passes a literal 3 today, so
  # there is no live defect — but keeper_interval_secs and its neighbours are already
  # config-sourced, and this is one typo away the moment the threshold joins them.
  case "$threshold" in
    ''|*[!0-9]*|0)
      printf 'vault-scan: cluster threshold must be a positive integer, got "%s"\n' "$threshold" >&2
      return 1
      ;;
  esac
  while IFS= read -r f; do
    dir="${f%/*}"
    base="${f##*/}"; base="${base%.md}"
    # No pre-folding: tokenize_slug splits on `-`, ` ` and `_` itself now (#36). Doing
    # it here was what let this caller and dedup_same_day disagree about the same
    # filename. `sort -u` below keeps the count "distinct files containing the token",
    # not total occurrences.
    slug="$base"
    rel="$(_scan_rel "$vault" "$dir")"
    tokenize_slug "$slug" | sort -u | while IFS= read -r tok; do
      [ -n "$tok" ] && printf '%s\t%s\n' "$rel" "$tok"
    done
  done < <(_scan_find_md "$vault") \
  | sort | uniq -c \
  | sed 's/^ *\([0-9][0-9]*\) /\1'"$(printf '\t')"'/' \
  | awk -F'\t' -v t="$threshold" '$1+0 >= t+0 { printf "CLUSTER\t%s\t%s\t%s\n", $2, $3, $1 }'
  return 0
}
