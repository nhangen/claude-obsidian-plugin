#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/frontmatter.sh"
. "${ROOT_DIR}/scripts/lib/vault-scan.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
has() { grep -qF "$1" <<<"$2" || fail "expected: $1"$'\n'"in:"$'\n'"$2"; }
lacks() { grep -qF "$1" <<<"$2" && fail "did NOT expect: $1"; return 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-scan-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
V="$TMP/vault"; mkdir -p "$V/Inbox" "$V/Projects" "$V/.obsidian" "$V/.trash"

note() { printf -- '---\n%s---\n\n%s\n' "$1" "$2" > "$V/$3"; }
note $'tags: [x]\ntype: a\n' 'clean'                  "Projects/good.md"
note $'tags: [x]\n'          'missing type'           "Projects/gap.md"
note ''                      'has [ask:where?] marker' "Projects/asky.md"
printf 'loose inbox note\n'  > "$V/Inbox/unfiled.md"
# excluded dirs must be ignored
note $'\n' 'x' ".obsidian/cfg.md"
note $'\n' 'x' ".trash/old.md"
# a .base file present — must never appear in any scan output
printf 'filters: {}\n' > "$V/_vaultkeeper.base"
# keeper-owned files at vault root — must never appear in any scan output
printf '## Open [ask] items\n\n- [ ] review foo\n' > "$V/Librarian.md"
printf '## Gap items\n\n- [ ] fix bar\n'            > "$V/Pending.md"
printf 'filters: {}\n'                              > "$V/keeper.base"
# cluster: 3 files sharing token "weekly" in Projects/
printf 'a\n' > "$V/Projects/weekly-review-1.md"
printf 'a\n' > "$V/Projects/weekly-review-2.md"
printf 'a\n' > "$V/Projects/weekly-sync-3.md"

GAPS="$(scan_frontmatter_gaps "$V" "tags type")"
has  "GAP"$'\t'"Projects/gap.md"$'\t'"type" "$GAPS"
lacks "GAP"$'\t'"Projects/good.md" "$GAPS"
lacks ".obsidian" "$GAPS"
lacks ".trash" "$GAPS"
lacks ".base" "$GAPS"

UNFILED="$(scan_unfiled "$V")"
has "UNFILED"$'\t'"Inbox/unfiled.md" "$UNFILED"

ASKS="$(scan_open_asks "$V")"
has "ASK"$'\t'"Projects/asky.md" "$ASKS"
lacks "ASK"$'\t'"Projects/good.md" "$ASKS"

CLUSTERS="$(scan_clusters "$V" 3)"
# "weekly" appears in 3 distinct files in Projects/ -> emitted with count 3.
has "CLUSTER"$'\t'"Projects"$'\t'"weekly"$'\t'"3" "$CLUSTERS"
# "review" appears in only 2 files (below threshold 3) -> must NOT be emitted.
lacks "CLUSTER"$'\t'"Projects"$'\t'"review" "$CLUSTERS"
grep -q '\.base' <<<"$CLUSTERS" && fail ".base leaked into clusters"

# Clustering routes through the shared tokenize_slug, so it agrees with dedup and
# MOC promotion instead of carrying a third inline tokenizer. The visible effect
# is case folding: these three belong to one cluster, and an uppercased token is
# not its own separate one.
mkdir -p "$V/Casing"
: > "$V/Casing/Alpha-first.md"
: > "$V/Casing/alpha-second.md"
: > "$V/Casing/ALPHA-third.md"
CCLUST="$(scan_clusters "$V" 3)"
has "CLUSTER"$'\t'"Casing"$'\t'"alpha"$'\t'"3" "$CCLUST"
grep -qF 'ALPHA' <<<"$CCLUST" && fail "cluster tokens must be case-folded, got:"$'\n'"$CCLUST"
# scan_* report on stdout; their exit status carries no "found something" signal.
# scan_clusters used to leak the status of its last threshold test, so one trailing
# folder with no above-threshold token made it return 1 after writing correct
# output — which aborts `X="$(scan_clusters …)"` under `set -e`.
#
# vaultkeeper-tick.sh happens to survive that, despite `set -euo pipefail`: its
# brace group ends with an `if` that returns 0 either way, so the scan's status
# never becomes the group's. Positional luck, not protection — move that `if` and
# the tick aborts. Verified both ways before writing this.
mkdir -p "$V/ZZlast"
: > "$V/ZZlast/solitary-note.md"
CRC=0; ( set -e; scan_clusters "$V" 3 >/dev/null ) || CRC=$?
[ "$CRC" = "0" ] || fail "scan_clusters returned $CRC with a below-threshold trailing folder"
GRC=0; ( set -e; scan_frontmatter_gaps "$V" "tags type" >/dev/null ) || GRC=$?
[ "$GRC" = "0" ] || fail "scan_frontmatter_gaps returned $GRC"
URC=0; ( set -e; scan_unfiled "$V" >/dev/null ) || URC=$?
[ "$URC" = "0" ] || fail "scan_unfiled returned $URC"
ARC=0; ( set -e; scan_open_asks "$V" >/dev/null ) || ARC=$?
[ "$ARC" = "0" ] || fail "scan_open_asks returned $ARC"
rm -rf "$V/ZZlast"

# The GRC arm above cannot fail on this fixture: $V always contains a gap file, so
# the loop's last body command succeeds and the natural status is already 0. The
# status only leaks when NO file has a gap — then the body ends on a false
# `[ -n "$miss" ] &&` and the while returns 1. Needs its own vault.
VC="$TMP/vault-complete"; mkdir -p "$VC"
printf -- '---\ntags: [x]\ntype: a\n---\n\nall fields present\n' > "$VC/complete-one.md"
printf -- '---\ntags: [y]\ntype: b\n---\n\nall fields present\n' > "$VC/complete-two.md"
[ -z "$(scan_frontmatter_gaps "$VC" "tags type")" ] || fail "complete vault should report no gaps"
GRC2=0; ( set -e; scan_frontmatter_gaps "$VC" "tags type" >/dev/null ) || GRC2=$?
[ "$GRC2" = "0" ] || fail "scan_frontmatter_gaps returned $GRC2 on a gap-free vault"

# Self-location: this lib resolves dedup-scan.sh next to itself at source time, so a
# cwd-relative capture leaves tokenize_slug undefined and clustering silently empty.
# It is the only one of the three captures whose failure also kills the caller —
# vaultkeeper-tick.sh runs `set -euo pipefail`, and a failed `.` aborts it at source
# time. Run from a foreign cwd under both shells; zsh is the one that regressed.
for _sh in bash zsh; do
  command -v "$_sh" >/dev/null 2>&1 || {
    printf 'SKIP: %s absent — self-location coverage did not run on this host\n' "$_sh" >&2
    continue
  }
  _out="$("$_sh" -c "cd / && set -u; . '$ROOT_DIR/scripts/lib/frontmatter.sh'; . '$ROOT_DIR/scripts/lib/vault-scan.sh'; scan_clusters '$V' 3" 2>"$TMP/selferr")" \
    || { cat "$TMP/selferr" >&2; fail "$_sh + foreign cwd: vault-scan could not locate its own dedup-scan.sh"; }
  grep -qF "CLUSTER"$'\t'"Projects"$'\t'"weekly" <<<"$_out" \
    || fail "$_sh + foreign cwd: clustering produced no tokens (tokenize_slug undefined?): [$_out]"
  [ -s "$TMP/selferr" ] && { cat "$TMP/selferr" >&2; fail "$_sh + foreign cwd: vault-scan wrote to stderr"; }
done

# Spaces still split into tokens (a filename with spaces is common in this vault).
mkdir -p "$V/Spaced"
: > "$V/Spaced/beta note one.md"
: > "$V/Spaced/beta note two.md"
: > "$V/Spaced/beta-note-three.md"
SCLUST="$(scan_clusters "$V" 3)"
has "CLUSTER"$'\t'"Spaced"$'\t'"beta"$'\t'"3" "$SCLUST"

# keeper-owned files must not appear in any scan output
for _scan_out in "$GAPS" "$ASKS" "$CLUSTERS"; do
  grep -qF 'Librarian.md' <<<"$_scan_out" && fail "Librarian.md leaked into scan output"
  grep -qF 'Pending.md'   <<<"$_scan_out" && fail "Pending.md leaked into scan output"
  grep -qF 'keeper.base'  <<<"$_scan_out" && fail ".base file leaked into scan output"
done
grep -qF 'Librarian.md' <<<"$UNFILED" && fail "Librarian.md leaked into UNFILED"
grep -qF 'Pending.md'   <<<"$UNFILED" && fail "Pending.md leaked into UNFILED"

# FIX D — space-in-filename must not produce spurious single-word tokens.
# "weekly review.md" has a space; without the fix, "review" becomes a lone token
# and could falsely inflate a cluster alongside the hyphen-split files.
mkdir -p "$V/SpaceTest"
printf 'a\n' > "$V/SpaceTest/weekly review.md"
printf 'a\n' > "$V/SpaceTest/weekly-review-1.md"
printf 'a\n' > "$V/SpaceTest/weekly-review-2.md"
SPACE_CLUSTERS="$(scan_clusters "$V" 2)"
# "weekly" appears across all 3 SpaceTest files (count >= 2) — must still be detected
has "CLUSTER"$'\t'"SpaceTest"$'\t'"weekly" "$SPACE_CLUSTERS"
# With the fix, "review" is split from "weekly review.md" via space→hyphen
# normalization, so it also counts across all 3 files — threshold met, emitted.
has "CLUSTER"$'\t'"SpaceTest"$'\t'"review" "$SPACE_CLUSTERS"
# Verify no cluster entry in SpaceTest shows count 1 (threshold is 2; all
# tokens should meet it — no spurious single-file tokens from word-splitting).
if printf '%s\n' "$SPACE_CLUSTERS" | grep "SpaceTest" | awk -F'\t' '{print $4}' | grep -q '^1$'; then
  fail "space-filename produced a spurious count-1 cluster token"
fi

# The canonical tokenizer wins over whatever the caller already had in scope. The
# old `command -v tokenize_slug ||` guard adopted the caller's definition instead,
# which is the drift the shared tokenizer exists to prevent.
HOSTILE="$(bash -c "tokenize_slug() { printf 'HOSTILE\n'; }; . '$ROOT_DIR/scripts/lib/frontmatter.sh'; . '$ROOT_DIR/scripts/lib/vault-scan.sh'; scan_clusters '$V' 3")"
grep -qF 'HOSTILE' <<<"$HOSTILE" && fail "a caller-defined tokenize_slug won over the canonical one: [$HOSTILE]"
grep -qF "CLUSTER"$'\t'"Projects"$'\t'"weekly" <<<"$HOSTILE" \
  || fail "canonical tokenizer produced no clusters after overriding the caller's: [$HOSTILE]"

# A missing dedup-scan.sh must be named at source time, not surface later as a
# clean-looking empty scan.
VSORPH="$TMP/vs-orphan"; mkdir -p "$VSORPH"
cp "$ROOT_DIR/scripts/lib/vault-scan.sh" "$VSORPH/"
if bash -c ". '$ROOT_DIR/scripts/lib/frontmatter.sh'; . '$VSORPH/vault-scan.sh'" 2>"$TMP/vserr"; then
  fail "sourcing vault-scan.sh without dedup-scan.sh beside it must fail"
fi
grep -q 'cannot source dedup-scan.sh' "$TMP/vserr" \
  || fail "missing tokenizer was not named; got: $(cat "$TMP/vserr")"

echo "PASS: vault-scan"
