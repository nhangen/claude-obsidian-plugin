#!/usr/bin/env bash
# allowlist-validate.sh — Project Taxonomy allow-list parsing + target validation.
# The taxonomy table in the config is the single source of valid top-level folders.
#
# EXIT CODES (#38). Every refusal used to return 1, distinguishable only by parsing
# English from stderr. That is fine for today's consumers — vault-librarian.md and the
# SKILL.md files are prose read by a model — and the prose is unchanged. It stops being
# fine the moment a shell caller needs to branch, and the design has `keeper insert`
# calling this as a guard; a shell script cannot switch on a sentence. One token per
# `return`, nothing lost for the LLM callers:
#
#   1  the target's top-level folder is not on the allow-list (a closest match is offered)
#   2  no config resolved — run /obsidian:setup
#   3  a config with no readable ## Project Taxonomy table
#   4  the install is broken (a sibling lib is missing, or the config cannot be read)
#
# 4 covers "present but unreadable" (chmod 000), which previously escaped as a raw
# `awk: can't open file …` and no `Refusing to write` line at all — a message matching
# none of the librarian's branches, so an LLM consumer had no defined behaviour for it.
# It belongs with "the install is broken" rather than "no config": the reader should not
# be sent to /obsidian:setup to re-create a config that is already there.
AV_E_NOT_ALLOWED=1
AV_E_NO_CONFIG=2
AV_E_NO_TAXONOMY=3
AV_E_BROKEN=4

# Captured at source time, not inside a function: `BASH_SOURCE` is a bashism that
# zsh leaves unset, and zsh's `$0` is the sourced file only while it is being
# read — inside a function it is the function name. Getting this wrong made
# every self-relative lookup cwd-relative under zsh (the librarian and keeper
# runtime), so config resolution failed and validation refused every write (#27).
_av_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

_allowlist_config() {
  local cfg="${1:-}"
  if [ -z "$cfg" ]; then
    # Check the capture landed somewhere real before trusting it. Testing for the
    # sibling rather than for an empty string catches both failure shapes: `cd`
    # failing (empty) and `dirname ""` -> "." -> `cd .` succeeding onto the
    # caller's cwd. Without this, either one resolves no config and reports it as
    # a missing config, sending the reader to /obsidian:setup for what is a broken
    # install — the same misdirection this file's own refusal was fixed for.
    if [ ! -f "${_av_lib_dir}/resolve-config.sh" ]; then
      printf 'allowlist: cannot find resolve-config.sh beside this lib (looked in "%s") — the install is broken, not the config\n' "$_av_lib_dir" >&2
      return "$AV_E_BROKEN"
    fi
    cfg="$(bash "${_av_lib_dir}/resolve-config.sh" 2>/dev/null || true)"
  fi
  [ -n "$cfg" ] && [ -f "$cfg" ] || { printf 'allowlist: no config resolved — run /obsidian:setup\n' >&2; return "$AV_E_NO_CONFIG"; }
  # Present but unreadable is a third state, and the one that used to escape as a raw
  # awk error with no refusal line (#38). Named here, before awk ever runs, so the
  # message is ours and matches a branch a consumer knows.
  if [ ! -r "$cfg" ]; then
    printf 'allowlist: the config at %s exists but cannot be read (check its permissions) — the install is broken, not the config\n' "$cfg" >&2
    return "$AV_E_BROKEN"
  fi
  printf '%s\n' "$cfg"
}

allowlist_list() {
  local cfg rc=0
  cfg="$(_allowlist_config "${1:-}")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  awk -F'|' '
    /^## Project Taxonomy/ { inseg=1; next }
    inseg && /^## / { inseg=0 }
    inseg && /^\|/ {
      v=$3; gsub(/^[ \t]+|[ \t]+$/, "", v);
      if (v=="" || v=="Vault path" || v ~ /^-+$/) next;
      sub(/\/$/, "", v);
      print v;
    }' "$cfg"
}

allowlist_validate() {
  local target="$1" cfg="${2:-}" entry ntarget nentry best="" bestd=9999 d top list
  # An empty list means no valid taxonomy rows parsed — a missing heading, or a
  # table with only a header. Distinct from "the target is not on the list", which
  # offers a closest match; reporting the former as the latter points the reader at
  # a typo in a target that was fine. The status is propagated rather than flattened
  # to 1, so "no config", "unreadable config" and "no taxonomy" stay distinguishable
  # to a shell caller (#38).
  local lrc=0
  list="$(allowlist_list "$cfg")" || lrc=$?
  [ "$lrc" -eq 0 ] || return "$lrc"
  if [ -z "$list" ]; then
    printf 'Refusing to write to %s — the config has no readable ## Project Taxonomy allow-list. Run /obsidian:setup or add the table.\n' "$target" >&2
    return "$AV_E_NO_TAXONOMY"
  fi

  ntarget="$(printf '%s' "$target" | tr 'A-Z' 'a-z')"; ntarget="${ntarget%/}"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    nentry="$(printf '%s' "$entry" | tr 'A-Z' 'a-z')"; nentry="${nentry%/}"
    case "$ntarget/" in
      "$nentry"/*) return 0 ;;
    esac
  done <<EOF
$list
EOF

  top="${target%%/*}"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    d="$(_lev "$(printf '%s' "$top" | tr 'A-Z' 'a-z')" "$(printf '%s' "${entry%%/*}" | tr 'A-Z' 'a-z')")"
    if [ "$d" -lt "$bestd" ]; then bestd="$d"; best="$entry"; fi
  done <<EOF
$list
EOF

  printf 'Refusing to write to %s — top-level folder is not in the allow-list. Closest match: %s. Add it to ## Project Taxonomy or correct the target.\n' "$target" "$best" >&2
  return "$AV_E_NOT_ALLOWED"
}

_lev() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    la=length(a); lb=length(b);
    for(i=0;i<=la;i++) d[i,0]=i;
    for(j=0;j<=lb;j++) d[0,j]=j;
    for(i=1;i<=la;i++) for(j=1;j<=lb;j++){
      c=(substr(a,i,1)==substr(b,j,1))?0:1;
      m=d[i-1,j]+1; n=d[i,j-1]+1; o=d[i-1,j-1]+c;
      m=(m<n)?m:n; m=(m<o)?m:o; d[i,j]=m;
    }
    print d[la,lb];
  }'
}
