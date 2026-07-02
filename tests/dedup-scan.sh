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

# dedup_same_day: same-day match above threshold is found; other-day ignored
mkdir -p "$TMP/f"
: > "$TMP/f/2026-06-29-keeper-cli-design.md"
: > "$TMP/f/2026-06-28-keeper-cli-notes.md"   # different day — must be ignored
hit="$(dedup_same_day "$TMP/f" 2026-06-29 keeper-cli-plan 0.4)"
echo "$hit" | grep -q '2026-06-29-keeper-cli-design.md' || fail "same-day match not found: [$hit]"
echo "$hit" | grep -q '2026-06-28' && fail "other-day file wrongly matched"
# below threshold -> no output
[ -z "$(dedup_same_day "$TMP/f" 2026-06-29 totally-unrelated-topic 0.4)" ] || fail "below-threshold should be empty"

# zsh cleanliness
if command -v zsh >/dev/null 2>&1; then
  zsh -c ". '$ROOT_DIR/scripts/lib/dedup-scan.sh'; tokenize_slug a-2026-bb" >/dev/null 2>"$TMP/zerr" || { cat "$TMP/zerr" >&2; fail "dedup-scan broke under zsh"; }
  grep -qi 'undefined signal\|bad pattern\|parse error' "$TMP/zerr" && { cat "$TMP/zerr" >&2; fail "zsh warning in dedup-scan"; }
fi
echo "PASS: dedup-scan"
