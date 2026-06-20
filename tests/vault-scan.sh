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

echo "PASS: vault-scan"
