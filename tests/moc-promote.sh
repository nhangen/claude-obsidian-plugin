#!/usr/bin/env bash
# Retargeting inbound wikilinks after an MOC promotion (#18).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/moc-promote.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/moc-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
V="$TMP/vault"; mkdir -p "$V/Projects/Foo/Panel/notes"

# The issue's repro: B and C promoted into Panel/notes/, D links to B by bare name.
printf 'moved b\n'  > "$V/Projects/Foo/Panel/notes/B.md"
printf 'moved c\n'  > "$V/Projects/Foo/Panel/notes/C.md"
printf 'see [[B]] and also [[C]] here\n' > "$V/Projects/Foo/D.md"
# Two occurrences in one file — the issue measured exactly this (4 links, 1 file with 2).
printf 'first [[B]]\nsecond [[B]]\n' > "$V/Projects/Foo/E.md"
# Forms that must be retargeted but keep their extras.
printf 'alias [[B|the b note]] and heading [[C#Findings]]\n' > "$V/Projects/Foo/F.md"
# Forms that must NOT be touched.
printf 'already pathed [[Panel/notes/B]]\nunrelated [[Bravo]]\nsubstring [[BB]]\n' > "$V/Projects/Foo/G.md"
printf 'no links at all\n' > "$V/Projects/Foo/H.md"
H_BEFORE="$(cat "$V/Projects/Foo/H.md")"
G_BEFORE="$(cat "$V/Projects/Foo/G.md")"

OUT="$(moc_retarget_wikilinks "$V" "Panel/notes" B C)" || fail "retarget returned non-zero"
LINKS="${OUT%% *}"; FILES="${OUT##* }"

grep -qxF -- 'see [[Panel/notes/B]] and also [[Panel/notes/C]] here' "$V/Projects/Foo/D.md" \
  || fail "bare inbound links were not retargeted: $(cat "$V/Projects/Foo/D.md")"
[ "$(grep -c 'Panel/notes/B' "$V/Projects/Foo/E.md")" = "2" ] \
  || fail "only one of two occurrences in a file was rewritten: $(cat "$V/Projects/Foo/E.md")"
grep -qF -- '[[Panel/notes/B|the b note]]' "$V/Projects/Foo/F.md" \
  || fail "an aliased link lost or kept the wrong target: $(cat "$V/Projects/Foo/F.md")"
grep -qF -- '[[Panel/notes/C#Findings]]' "$V/Projects/Foo/F.md" \
  || fail "a heading link lost or kept the wrong target: $(cat "$V/Projects/Foo/F.md")"

# No double-prefixing, no fuzzy matching. `[[Bravo]]` and `[[BB]]` merely start with
# the stem; rewriting either would point at a file that does not exist.
[ "$(cat "$V/Projects/Foo/G.md")" = "$G_BEFORE" ] \
  || fail "an already-pathed or unrelated link was rewritten:"$'\n'"$(cat "$V/Projects/Foo/G.md")"
[ "$(cat "$V/Projects/Foo/H.md")" = "$H_BEFORE" ] \
  || fail "a file with no matching links was rewritten anyway"

# The count is what the confirmation message reports, so it has to be right:
# D has 2, E has 2, F has 2 → 6 links across 3 files.
[ "$LINKS" = "6" ] || fail "reported $LINKS links updated, expected 6"
[ "$FILES" = "3" ] || fail "reported $FILES files changed, expected 3"

# Idempotent: everything is pathed now, so a second run changes nothing.
OUT2="$(moc_retarget_wikilinks "$V" "Panel/notes" B C)"
[ "$OUT2" = "0 0" ] || fail "a second run rewrote something: [$OUT2]"

# --- filenames that are not safe regexes --------------------------------------
# A sed-based rewrite would need every one of these escaped; matching the target
# literally means there is nothing to escape. Note what is NOT in this list: `[`, `]`,
# `#`, `^` and `|` cannot appear in a linkable note name — Obsidian forbids them
# precisely because they make `[[...]]` ambiguous — so a name containing them is not a
# case this has to handle.
V2="$TMP/vault2"; mkdir -p "$V2/notes"
for _n in 'a.b+c' 'x(1)' 'with space' 'dots...many' '100%-done'; do
  printf 'moved\n' > "$V2/notes/${_n}.md"
  printf 'ref [[%s]] end\n' "$_n" > "$V2/src-${_n}.md"
done
OUT3="$(moc_retarget_wikilinks "$V2" "notes" 'a.b+c' 'x(1)' 'with space' 'dots...many' '100%-done')" \
  || fail "retarget failed on regex-unsafe names"
[ "${OUT3%% *}" = "5" ] || fail "regex-unsafe names: reported ${OUT3%% *} links, expected 5"
grep -qxF -- 'ref [[notes/a.b+c]] end' "$V2/src-a.b+c.md" \
  || fail "a name with . and + was not retargeted: $(cat "$V2/src-a.b+c.md")"
grep -qxF -- 'ref [[notes/100%-done]] end' "$V2/src-100%-done.md" \
  || fail "a name with % was not retargeted: $(cat "$V2/src-100%-done.md")"
grep -qxF -- 'ref [[notes/with space]] end' "$V2/src-with space.md" \
  || fail "a name with a space was not retargeted: $(cat "$V2/src-with space.md")"

# --- guards -------------------------------------------------------------------
moc_retarget_wikilinks "$TMP/nope" "x" B 2>/dev/null \
  && fail "a missing vault must be refused"
moc_retarget_wikilinks "$V" "" B 2>/dev/null \
  && fail "an empty prefix must be refused rather than rewriting links to a bare /"
[ "$(moc_retarget_wikilinks "$V" "Panel/notes")" = "0 0" ] \
  || fail "no stems should be a no-op, not an error"

# A leading or trailing slash in the prefix must not produce `//` or a leading `/`,
# neither of which Obsidian resolves.
V3="$TMP/vault3"; mkdir -p "$V3"
printf 'ref [[Z]]\n' > "$V3/s.md"
moc_retarget_wikilinks "$V3" "/Deep/Path/" Z >/dev/null
grep -qxF -- 'ref [[Deep/Path/Z]]' "$V3/s.md" \
  || fail "prefix slashes were not normalised: $(cat "$V3/s.md")"

echo "PASS: moc-promote"
