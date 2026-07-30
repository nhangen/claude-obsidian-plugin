#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/seed-schema-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
VAULT="$TMP/vault"; mkdir -p "$VAULT"

mknote() { printf -- '---\n%s---\n\nbody\n' "$1" > "$VAULT/$2"; }
# 4 of 5 notes have tags+type (80%); date only in 1 (20%)
mknote $'tags: [x]\ntype: a\ndate: 1\n' n1.md
mknote $'tags: [x]\ntype: a\n'          n2.md
mknote $'tags: [x]\ntype: a\n'          n3.md
mknote $'tags: [x]\ntype: a\n'          n4.md
mknote $'title: x\n'                    n5.md

CFG="$TMP/obsidian.local.md"
printf -- '---\nvault_path: %s\n---\n' "$VAULT" > "$CFG"

OUT="$(bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG")"
grep -q '^frontmatter_required:' "$CFG" || fail "config not seeded"
SEEDED="$(grep '^frontmatter_required:' "$CFG" | sed 's/frontmatter_required: *//')"
grep -qw tags <<<"$SEEDED" || fail "tags (80%) should be required: $SEEDED"
grep -qw type <<<"$SEEDED" || fail "type (80%) should be required: $SEEDED"
grep -qw date <<<"$SEEDED" && fail "date (20%) must NOT be required: $SEEDED"

# Idempotent: a second run must not duplicate or overwrite the existing line.
bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG" >/dev/null
[ "$(grep -c '^frontmatter_required:' "$CFG")" -eq 1 ] || fail "duplicate frontmatter_required line"

# Explicit pre-existing value is preserved, not recomputed.
CFG2="$TMP/cfg2.md"
printf -- '---\nvault_path: %s\nfrontmatter_required: project\n---\n' "$VAULT" > "$CFG2"
bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG2" >/dev/null
[ "$(grep '^frontmatter_required:' "$CFG2" | sed 's/.*: *//')" = "project" ] || fail "existing value overwritten"

# --- nothing derivable: leave the key UNSET, and say so (#46) ----------------
# Writing `frontmatter_required:` empty is what stranded a host: readers fall back to
# a hardcoded `tags type`, so the librarian nudges for keys the vault does not use,
# and the seed's own presence check then short-circuits forever — on the one host
# where a retry can never happen. An absent key is what lets a later session retry.
EV="$TMP/emptyvault"; mkdir -p "$EV"
printf -- '---\nunique1: a\n---\n\nbody\n' > "$EV/a.md"
printf -- '---\nunique2: b\n---\n\nbody\n' > "$EV/b.md"
printf -- '---\nunique3: c\n---\n\nbody\n' > "$EV/c.md"
CFG3="$TMP/cfg3.md"
printf -- '---\nvault_path: %s\n---\n' "$EV" > "$CFG3"
EERR="$(bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$EV" "$CFG3" 2>&1 >/dev/null)" \
  && fail "the seed reported success when it derived nothing"
grep -q '^frontmatter_required:' "$CFG3" \
  && fail "the seed wrote an empty frontmatter_required, which no later run can undo: $(cat "$CFG3")"
[ -n "$EERR" ] \
  || fail "the seed derived nothing and said nothing; the caller has no reason to quote"

# An empty vault is the same case, not a crash.
EV2="$TMP/novault"; mkdir -p "$EV2"
CFG4="$TMP/cfg4.md"; printf -- '---\nvault_path: %s\n---\n' "$EV2" > "$CFG4"
bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$EV2" "$CFG4" >/dev/null 2>&1 \
  && fail "an empty vault must not report a successful seed"
grep -q '^frontmatter_required:' "$CFG4" \
  && fail "an empty vault seeded an empty frontmatter_required: $(cat "$CFG4")"

# --- a host already stranded with an empty value heals (#46) ------------------
# Present-but-empty must read as not-yet-seeded, or the hosts that already have the
# bad line stay broken forever.
CFG5="$TMP/cfg5.md"
printf -- '---\nvault_path: %s\nfrontmatter_required:\n---\n' "$VAULT" > "$CFG5"
bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG5" >/dev/null \
  || fail "the seed refused to re-derive over a present-but-empty value"
HEALED="$(grep '^frontmatter_required:' "$CFG5" | sed 's/frontmatter_required: *//')"
grep -qw tags <<<"$HEALED" || fail "an empty value was not healed: [$HEALED]"
[ "$(grep -c '^frontmatter_required:' "$CFG5")" -eq 1 ] \
  || fail "healing duplicated the frontmatter_required line: $(cat "$CFG5")"

# --- a failed swap discards the staged temp (#43 sibling site) ----------------
# This script had its own unguarded mktemp → render → bare `mv`, which the #43 audit
# did not list.
if [ "$(id -u)" = "0" ]; then
  echo "note: running as root, skipping the seed's failed-swap arm" >&2
else
  CFG6D="$TMP/rocfg"; mkdir -p "$CFG6D"
  CFG6="$CFG6D/obsidian.local.md"
  printf -- '---\nvault_path: %s\n---\n' "$VAULT" > "$CFG6"
  LEAKD="$TMP/seedleak"; mkdir -p "$LEAKD"
  chmod a-w "$CFG6D"
  ( TMPDIR="$LEAKD" bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG6" >/dev/null 2>&1 ) \
    && { chmod u+w "$CFG6D"; fail "the seed reported success when it could not write the config"; }
  chmod u+w "$CFG6D"
  LEFT="$(find "$LEAKD" -name 'cfg-*' -type f | wc -l | tr -d ' ')"
  [ "$LEFT" = "0" ] || fail "the seed leaked $LEFT temp file(s) when the swap failed"
fi

echo "PASS: seed-frontmatter-schema"
