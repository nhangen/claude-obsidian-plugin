#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/dedup-scan.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dedup-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# tokenize_slug: drop purely-numeric and 1-char tokens, keep 2-char, lowercase
got="$(tokenize_slug "2026-06-29-Keeper-a-PR-ai" | tr '\n' ' ')"
[ "$got" = "keeper pr ai " ] || fail "tokenize_slug got: [$got]"

# jaccard: identical slugs = 1.00, disjoint = 0.00
[ "$(jaccard keeper-cli keeper-cli)" = "1.00" ] || fail "jaccard identical"
[ "$(jaccard alpha-beta gamma-delta)" = "0.00" ] || fail "jaccard disjoint"
# half overlap: {keeper,cli} vs {keeper,gui} -> inter 1 / union 3 = 0.33
[ "$(jaccard keeper-cli keeper-gui)" = "0.33" ] || fail "jaccard partial: $(jaccard keeper-cli keeper-gui)"
# all-numeric slugs produce empty token sets; must yield 0.00 and not abort under set -e
# Direct-call form (no $(...)) is the mutation check: broken grep -c aborts the subshell here.
bash -c "set -euo pipefail; . '$ROOT_DIR/scripts/lib/dedup-scan.sh'; jaccard 2026-01 2026-02" | grep -q '^0\.00$' || fail "all-numeric jaccard should be 0.00 and not abort"

# dedup_same_day: same-day match above threshold is found; other-day ignored
mkdir -p "$TMP/f"
: > "$TMP/f/2026-06-29-keeper-cli-design.md"
: > "$TMP/f/2026-06-28-keeper-cli-notes.md"   # different day — must be ignored
hit="$(dedup_same_day "$TMP/f" 2026-06-29 keeper-cli-plan 0.4)"
echo "$hit" | grep -q '2026-06-29-keeper-cli-design.md' || fail "same-day match not found: [$hit]"
echo "$hit" | grep -q '2026-06-28' && fail "other-day file wrongly matched"
# below threshold -> no output
[ -z "$(dedup_same_day "$TMP/f" 2026-06-29 totally-unrelated-topic 0.4)" ] || fail "below-threshold should be empty"

dedup_same_day "$TMP/f" 2026-06-29 zzz-no-such-topic 0.4 >/dev/null
echo "ok: bare no-match dedup_same_day survived set -e" >/dev/null

# --- the per-vault threshold override actually reaches the scanner (#103) ---
# `keeper-cli` vs `keeper-gui` scores 0.33: below the 0.4 default, above a
# vault that lowered the bar. A config override that never arrives is invisible
# in the result, which is how every call site ran at 0.4 while the vault said
# otherwise.
mkdir -p "$TMP/t"
: > "$TMP/t/2026-06-29-keeper-gui.md"
CFG="$TMP/obsidian.local.md"
printf -- '---\nvault_path: %s\ndedup_jaccard_threshold: 0.2\n---\n' "$TMP" > "$CFG"

# Scrub the resolver's inputs for this one: the developer running the suite may
# well have a real config, and the default-path assertion must not read it.
[ -z "$(HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/noconfig" CLAUDE_PLUGIN_ROOT="" \
        dedup_same_day "$TMP/t" 2026-06-29 keeper-cli)" ] \
  || fail "with no config the arg-less call must use the 0.4 default"

hit="$(OBSIDIAN_LOCAL_MD="$CFG" dedup_same_day "$TMP/t" 2026-06-29 keeper-cli)"
echo "$hit" | grep -q '2026-06-29-keeper-gui.md' \
  || fail "the vault's dedup_jaccard_threshold override never reached the scanner: [$hit]"

# an explicit argument still wins over the config
[ -z "$(OBSIDIAN_LOCAL_MD="$CFG" dedup_same_day "$TMP/t" 2026-06-29 keeper-cli 0.4)" ] \
  || fail "an explicit threshold argument must override the config"

# a config value the scanner cannot use warns and falls back, rather than
# reaching awk — where a non-numeric threshold compares as 0 and matches the
# first note in the folder.
printf -- '---\ndedup_jaccard_threshold: high\n---\n' > "$TMP/bad.md"
BADOUT="$(OBSIDIAN_LOCAL_MD="$TMP/bad.md" dedup_same_day "$TMP/t" 2026-06-29 keeper-cli 2>"$TMP/bad.err")"
[ -z "$BADOUT" ] || fail "an unusable threshold matched anyway: [$BADOUT]"
grep -q 'unusable dedup_jaccard_threshold' "$TMP/bad.err" \
  || fail "an unusable threshold was swallowed:"$'\n'"$(cat "$TMP/bad.err")"

# a vault that raises the bar suppresses a match the default would have made
: > "$TMP/t/2026-06-29-keeper-cli-design.md"
printf -- '---\ndedup_jaccard_threshold: 1.0\n---\n' > "$TMP/off.md"
[ -z "$(OBSIDIAN_LOCAL_MD="$TMP/off.md" dedup_same_day "$TMP/t" 2026-06-29 keeper-cli-plan)" ] \
  || fail "dedup_jaccard_threshold: 1.0 must disable the check"

# zsh cleanliness
if command -v zsh >/dev/null 2>&1; then
  zsh -c ". '$ROOT_DIR/scripts/lib/dedup-scan.sh'; tokenize_slug a-2026-bb" >/dev/null 2>"$TMP/zerr" || { cat "$TMP/zerr" >&2; fail "dedup-scan broke under zsh"; }
  grep -qi 'undefined signal\|bad pattern\|parse error' "$TMP/zerr" && { cat "$TMP/zerr" >&2; fail "zsh warning in dedup-scan"; }
  zsh -c ". '$ROOT_DIR/scripts/lib/dedup-scan.sh'; jaccard keeper-cli keeper-gui" >/dev/null 2>>"$TMP/zerr" || { cat "$TMP/zerr" >&2; fail "jaccard broke under zsh"; }
  # dedup_same_day smoke under zsh (match still works).
  zt="$(mktemp -d "${TMPDIR:-/tmp}/dedupz-XXXXXX")"; : > "$zt/2026-06-29-alpha-beta.md"
  m="$(zsh -c ". '$ROOT_DIR/scripts/lib/dedup-scan.sh'; dedup_same_day '$zt' 2026-06-29 alpha-beta 0.4")"
  echo "$m" | grep -q 'alpha-beta' || fail "dedup_same_day match failed under zsh"
  rm -rf "$zt"
fi

# Structural guard: the same-day scan must use find, never a bare glob-for. The
# `for f in "$dir"/*.md` idiom errors under rc'd interactive zsh (nomatch) on the
# common no-match path; that failure can't be reproduced portably via `zsh -c`,
# so guard the implementation shape directly.
grep -Eq 'for[[:space:]]+[A-Za-z_]+[[:space:]]+in[^;]*\*\.md' "$ROOT_DIR/scripts/lib/dedup-scan.sh" \
  && fail "same-day scan must use find, not a glob-for (breaks under zsh nomatch)"
grep -q 'find .* -name' "$ROOT_DIR/scripts/lib/dedup-scan.sh" \
  || fail "dedup_same_day should scan via find"
# --- the tokenizer folds spaces and underscores itself (#36) ------------------
# It split on `-` only, and the two callers disagreed as a result: scan_clusters
# pre-folded spaces, dedup_same_day did not. So a note saved with spaces in its name
# was invisible to same-day dedup against its hyphenated twin — the exact filenames
# this vault contains. The issue measured 0.00 vs 0.50 for this pair.
J1="$(jaccard "beta note one" "beta-note-two")"
J2="$(jaccard "beta-note-one" "beta-note-two")"
[ "$J1" = "$J2" ] \
  || fail "a space-named note scores $J1 against a hyphenated sibling while its hyphenated twin scores $J2; dedup cannot see it"
case "$J1" in
  0|0.00|0.0) fail "the space-named pair still scores zero: $J1" ;;
esac
# Underscores too — the other separator a filename arrives with.
J3="$(jaccard "beta_note_one" "beta-note-two")"
[ "$J3" = "$J2" ] || fail "an underscore-named note scores $J3, hyphenated twin scores $J2"
# Mixed separators in one name must tokenize the same as any other spelling.
[ "$(tokenize_slug "alpha beta_gamma-delta" | sort | paste -sd, -)" = "alpha,beta,delta,gamma" ] \
  || fail "mixed separators did not tokenize: $(tokenize_slug "alpha beta_gamma-delta" | sort | paste -sd, -)"

echo "PASS: dedup-scan"
