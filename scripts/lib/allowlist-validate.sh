#!/usr/bin/env bash
# allowlist-validate.sh — Project Taxonomy allow-list parsing + target validation.
# The taxonomy table in the config is the single source of valid top-level folders.

_allowlist_config() {
  local cfg="${1:-}"
  if [ -z "$cfg" ]; then
    cfg="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-config.sh" 2>/dev/null || true)"
  fi
  [ -n "$cfg" ] && [ -f "$cfg" ] || { printf 'allowlist: no config resolved\n' >&2; return 1; }
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
  local target="$1" cfg="${2:-}" entry ntarget nentry best="" bestd=9999 d top
  ntarget="$(printf '%s' "$target" | tr 'A-Z' 'a-z')"; ntarget="${ntarget%/}"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    nentry="$(printf '%s' "$entry" | tr 'A-Z' 'a-z')"; nentry="${nentry%/}"
    case "$ntarget/" in
      "$nentry"/*) return 0 ;;
    esac
  done < <(allowlist_list "$cfg")

  top="${target%%/*}"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    d="$(_lev "$(printf '%s' "$top" | tr 'A-Z' 'a-z')" "$(printf '%s' "${entry%%/*}" | tr 'A-Z' 'a-z')")"
    if [ "$d" -lt "$bestd" ]; then bestd="$d"; best="$entry"; fi
  done < <(allowlist_list "$cfg")

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
