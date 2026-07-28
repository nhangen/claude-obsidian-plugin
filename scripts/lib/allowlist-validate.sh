#!/usr/bin/env bash
# allowlist-validate.sh — Project Taxonomy allow-list parsing + target validation.
# The taxonomy table in the config is the single source of valid top-level folders.

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
      return 1
    fi
    cfg="$(bash "${_av_lib_dir}/resolve-config.sh" 2>/dev/null || true)"
  fi
  [ -n "$cfg" ] && [ -f "$cfg" ] || { printf 'allowlist: no config resolved — run /obsidian:setup\n' >&2; return 1; }
  printf '%s\n' "$cfg"
}

allowlist_list() {
  local cfg; cfg="$(_allowlist_config "${1:-}")" || return 1
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
  # a typo in a target that was fine. A config that is present but unreadable does
  # not arrive here: awk fails, allowlist_list propagates, and the `|| return 1`
  # below short-circuits.
  list="$(allowlist_list "$cfg")" || return 1
  if [ -z "$list" ]; then
    printf 'Refusing to write to %s — the config has no readable ## Project Taxonomy allow-list. Run /obsidian:setup or add the table.\n' "$target" >&2
    return 1
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
  return 1
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
