#!/usr/bin/env bash
# moc-promote.sh — retarget inbound wikilinks after an MOC promotion moves notes
# into a subfolder. Requires note-hash.sh (keeper_swap_or_clean).
#
# Obsidian's "Update internal links on rename" only fires inside the running app's
# rename UI. The promotion flow moves files with a shell `mv`, which bypasses it, so
# the skill used to warn about the broken links and hand the repair back to the user
# (#18). Once the user has accepted the promotion they have already accepted the link
# churn, and the repair is mechanical: the pre-move scan already knows which files
# reference the moved notes.
#
# Matching is exact on the link TARGET, and done by string scanning rather than a
# regex, because a note filename is not a safe regex: this vault has names with `.`,
# `+`, `(`, `[` and spaces in them, and escaping each for sed is how a "safe minimum"
# rewrite starts corrupting notes. The target is compared literally.
#
# `[[stem]]`, `[[stem|alias]]` and `[[stem#heading]]` are all retargeted — same link,
# extras preserved. `[[Some/Path/stem]]` is left alone: it already resolves, and
# prefixing it again would break it.

# moc_retarget_wikilinks <vault> <new-prefix> <stem> [<stem>...]
# Rewrites `[[<stem>]]` to `[[<new-prefix>/<stem>]]` across every .md in the vault.
# Prints `<links-updated> <files-changed>`; returns 1 if nothing could be scanned.
moc_retarget_wikilinks() {
  local vault="$1" prefix="$2"; shift 2
  [ -d "$vault" ] || { printf 'moc-promote: not a directory: %s\n' "$vault" >&2; return 1; }
  [ -n "$prefix" ] || { printf 'moc-promote: empty target prefix; refusing to rewrite links to a bare "/"\n' >&2; return 1; }
  [ $# -gt 0 ] || { printf '0 0\n'; return 0; }

  # Strip any leading/trailing slash so the rendered link cannot end up with `//`
  # or a leading `/` (which Obsidian does not resolve).
  prefix="${prefix#/}"; prefix="${prefix%/}"

  local stems_file total_links=0 total_files=0 f out changed
  stems_file="$(mktemp "${TMPDIR:-/tmp}/mocstems-XXXXXX")" || return 1
  printf '%s\n' "$@" > "$stems_file"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    out="$(mktemp "${TMPDIR:-/tmp}/mocrw-XXXXXX")" || { rm -f "$stems_file"; return 1; }
    changed="$(_moc_rewrite_file "$f" "$prefix" "$stems_file" "$out")" || changed=0
    case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
    if [ "$changed" -gt 0 ]; then
      if keeper_swap_or_clean "$out" "$f"; then
        total_links=$(( total_links + changed ))
        total_files=$(( total_files + 1 ))
      fi
    else
      rm -f "$out"
    fi
  done <<EOF
$(find "$vault" -type f -name '*.md' \
    ! -path '*/.obsidian/*' ! -path '*/.trash/*' ! -path '*/.git/*' \
    ! -path '*/.vaultkeeper-quarantine/*' ! -path '*/.vaultkeeper/*' 2>/dev/null)
EOF

  rm -f "$stems_file"
  printf '%s %s\n' "$total_links" "$total_files"
}

# Writes the rewritten file to <out> and prints how many links it changed.
_moc_rewrite_file() {
  awk -v prefix="$2" -v stemfile="$3" -v outfile="$4" '
    BEGIN {
      while ((getline s < stemfile) > 0) { if (s != "") stems[s] = 1 }
      close(stemfile)
      n = 0
    }
    {
      line = $0
      rebuilt = ""
      rest = line
      while (1) {
        o = index(rest, "[[")
        if (o == 0) { rebuilt = rebuilt rest; break }
        c = index(substr(rest, o + 2), "]]")
        if (c == 0) { rebuilt = rebuilt rest; break }
        inner = substr(rest, o + 2, c - 1)
        head = substr(rest, 1, o + 1)
        rest = substr(rest, o + 2 + c + 1)

        # Split the target off any |alias or #heading; whichever comes first wins.
        extra = ""
        target = inner
        pipe = index(inner, "|"); hash = index(inner, "#")
        cut = 0
        if (pipe > 0 && (hash == 0 || pipe < hash)) cut = pipe
        else if (hash > 0) cut = hash
        if (cut > 0) { target = substr(inner, 1, cut - 1); extra = substr(inner, cut) }

        # Already carries a path — leave it, prefixing again would break it.
        if (index(target, "/") == 0 && (target in stems)) {
          inner = prefix "/" target extra
          n++
        }
        rebuilt = rebuilt head inner "]]"
      }
      print rebuilt > outfile
    }
    END { close(outfile); print n }
  ' "$1"
}
