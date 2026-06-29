#!/usr/bin/env bash
# keeper-save-payload.sh — parse + validate the agent-facing keeper-save payload.
# Format: header lines `key: value` (title/folder_hint/type/links), then a line
# that is exactly `---`, then the body. Dependency-free (no JSON parser).

kspayload_field() {
  awk -v k="$2" '
    $0=="---" { exit }
    {
      idx=index($0,":")
      if (idx>0) {
        key=substr($0,1,idx-1)
        if (key==k) { v=substr($0,idx+1); sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v); print v; exit }
      }
    }
  ' "$1"
}

kspayload_body() {
  awk 'seen{print} $0=="---"{seen=1}' "$1"
}

kspayload_validate() {
  local op title body date target
  op="$(kspayload_field "$1" op)"; [ -z "$op" ] && op="insert"
  body="$(kspayload_body "$1" | sed '/^[[:space:]]*$/d')"

  case "$op" in
    insert)
      title="$(kspayload_field "$1" title)"
      if [ -z "$title" ]; then
        printf 'keeper-save: missing required field: title\n' >&2; return 1
      fi
      if [ -z "$body" ]; then
        printf 'keeper-save: missing required field: body\n' >&2; return 1
      fi
      ;;
    append)
      date="$(kspayload_field "$1" date)"
      target="$(kspayload_field "$1" target)"
      if [ -z "$date" ] && [ -z "$target" ]; then
        printf 'keeper-save: append requires a date or target\n' >&2; return 1
      fi
      if [ -z "$body" ]; then
        printf 'keeper-save: missing required field: body\n' >&2; return 1
      fi
      ;;
    *)
      printf 'keeper-save: unknown op: %s (expected insert or append)\n' "$op" >&2; return 1
      ;;
  esac
}

kspayload_links() {
  local raw
  raw="$(kspayload_field "$1" links)"
  [ -z "$raw" ] && return 0
  # append a trailing newline so `read` captures the last item when no trailing newline exists
  printf '%s\n' "$raw" | tr ',' '\n' | while IFS= read -r l; do
    l="$(printf '%s' "$l" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$l" ] && printf '[[%s]]\n' "$l"
  done
}
