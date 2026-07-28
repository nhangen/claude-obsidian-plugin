#!/usr/bin/env bash
# vault-index-links.sh — issue #30: state must never claim coverage INDEX.md lacks.
# apply writes the links itself; plan treats "hashed but unlinked" as an ADD.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-links-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# --- apply writes the link, not just the hash ---
F="$TMP/Decisions"; mkdir -p "$F"
IDX="$F/INDEX.md"; printf '# Decisions Index\n' > "$IDX"
printf 'note A\n' > "$F/a.md"
printf 'note B\n' > "$F/b.md"
STATE="$(index_state_file "$IDX")"

vault_index_apply "$F" "$IDX" >/dev/null
grep -qxF -- '- [[a]]' "$IDX" || fail "apply did not write link for a.md"$'\n'"$(cat "$IDX")"
grep -qxF -- '- [[b]]' "$IDX" || fail "apply did not write link for b.md"
# Append-only: the pre-existing header survives, at the top.
[ "$(head -1 "$IDX")" = '# Decisions Index' ] || fail "apply rewrote INDEX.md instead of appending"

# --- idempotent: a second apply adds no duplicate link ---
touch -t 202001010000 "$F/a.md" "$F/b.md"
vault_index_apply "$F" "$IDX" >/dev/null
[ "$(grep -cxF -- '- [[a]]' "$IDX")" = 1 ] || fail "duplicate link appended for a.md"

# --- self-heal: state ahead of INDEX (the issue-30 drift) must reappear as ADD ---
# Simulate the damaged vault: drop a.md's link from INDEX while its hash stays in state.
grep -vxF -- '- [[a]]' "$IDX" > "$IDX.tmp" && mv "$IDX.tmp" "$IDX"
grep -qxF -- '- [[a]]' "$IDX" && fail "setup: a.md link should be gone"
note_hash_valid "$(state_hash_for "$STATE" "a.md")" || fail "setup: a.md hash should still be in state"

PLAN="$(vault_index_plan "$F" "$IDX")"
grep -qxF "ADD"$'\t'"a.md" <<<"$PLAN" \
  || fail "hashed-but-unlinked note must plan as ADD, got:"$'\n'"$PLAN"

ADDED="$(vault_index_apply "$F" "$IDX")"
grep -qxF "a.md" <<<"$ADDED" || fail "drifted note must be reported in the ADD set"
grep -qxF -- '- [[a]]' "$IDX" || fail "apply did not re-add the missing link"

# --- a hand-written link is respected: no ADD, no duplicate ---
F2="$TMP/Hand"; mkdir -p "$F2"
IDX2="$F2/INDEX.md"; printf '# Hand Index\n- [[h]]\n' > "$IDX2"
printf 'hand note\n' > "$F2/h.md"
vault_index_apply "$F2" "$IDX2" >/dev/null
[ "$(grep -cxF -- '- [[h]]' "$IDX2")" = 1 ] || fail "apply duplicated a hand-written link"

# Link variants (alias / heading) count as linked.
F3="$TMP/Variants"; mkdir -p "$F3"
IDX3="$F3/INDEX.md"; printf '# V Index\n- [[v1|Alias]]\n- [[v2#Section]]\n' > "$IDX3"
printf 'v1\n' > "$F3/v1.md"; printf 'v2\n' > "$F3/v2.md"
vault_index_apply "$F3" "$IDX3" >/dev/null
[ "$(grep -c -- '\[\[v1' "$IDX3")" = 1 ] || fail "aliased link not recognized as coverage"
[ "$(grep -c -- '\[\[v2' "$IDX3")" = 1 ] || fail "heading link not recognized as coverage"

# --- titles with regex metacharacters must match literally ---
F4="$TMP/Meta"; mkdir -p "$F4"
IDX4="$F4/INDEX.md"; printf '# Meta Index\n' > "$IDX4"
printf 'meta\n' > "$F4/2026-07-27 notes (draft) [v1+2].md"
vault_index_apply "$F4" "$IDX4" >/dev/null
grep -qxF -- '- [[2026-07-27 notes (draft) [v1+2]]]' "$IDX4" \
  || fail "metachar title not linked literally:"$'\n'"$(cat "$IDX4")"
touch -t 202001010000 "$F4/2026-07-27 notes (draft) [v1+2].md"
vault_index_apply "$F4" "$IDX4" >/dev/null
[ "$(grep -c -- '\[\[2026-07-27' "$IDX4")" = 1 ] || fail "metachar title link duplicated"

# --- missing INDEX.md is created, not silently skipped ---
F5="$TMP/Fresh"; mkdir -p "$F5"
IDX5="$F5/INDEX.md"
printf 'fresh\n' > "$F5/f.md"
vault_index_apply "$F5" "$IDX5" >/dev/null
[ -f "$IDX5" ] || fail "apply did not create a missing INDEX.md"
grep -qxF -- '- [[f]]' "$IDX5" || fail "apply did not link into the created INDEX.md"

# --- coverage check: state tracking more notes than INDEX links is a defect ---
# Callable on its own so a damaged vault can be assessed without a write.
vault_index_coverage_check "$F" "$IDX" 2>/dev/null || fail "healthy slice reported as a defect"
grep -vxF -- '- [[b]]' "$IDX" > "$IDX.tmp" && mv "$IDX.tmp" "$IDX"
if WARN="$(vault_index_coverage_check "$F" "$IDX" 2>&1 >/dev/null)"; then
  fail "coverage check passed while INDEX had fewer links than state tracks"
fi
case "$WARN" in *coverage*) : ;; *) fail "coverage defect not reported on stderr: $WARN" ;; esac

# apply runs the check itself, so the defect cannot be skipped by a caller that
# forgets to ask — and it heals the gap it just reported.
vault_index_apply "$F" "$IDX" >/dev/null
vault_index_coverage_check "$F" "$IDX" 2>/dev/null || fail "apply left a coverage defect behind"

# --- empty folder: neither state nor INDEX exists yet; must not abort set -e ---
F6="$TMP/Empty"; mkdir -p "$F6"
vault_index_apply "$F6" "$F6/INDEX.md" >/dev/null
vault_index_coverage_check "$F6" "$F6/INDEX.md" 2>/dev/null \
  || fail "coverage check failed on an empty folder"

echo "PASS: vault-index-links"

# --- recursion: notes below the root are tracked, not reported deleted -------
# Regression guard for the second half of #30 (see #32): a single-level glob
# reported every relocated note as a DROP and tracked none of them, so
# organizing a folder silently untracked it.
R="$TMP/Recursive"; mkdir -p "$R/sub/deep"
RIDX="$R/INDEX.md"; printf '# Recursive Index\n' > "$RIDX"
printf 'flat\n'  > "$R/flat.md"
printf 'one\n'   > "$R/sub/one.md"
printf 'two\n'   > "$R/sub/deep/two.md"
RSTATE="$(index_state_file "$RIDX")"

vault_index_apply "$R" "$RIDX" >/dev/null
for n in flat sub/one sub/deep/two; do
  grep -qxF -- "- [[$n]]" "$RIDX" || fail "recursion: no link written for $n"$'\n'"$(cat "$RIDX")"
done
[ "$(grep -vc '^#' "$RSTATE")" = "3" ] || fail "recursion: expected 3 tracked, got $(grep -vc '^#' "$RSTATE")"$'\n'"$(cat "$RSTATE")"
# state must be keyed by folder-relative path, or two same-named notes in
# different subfolders collide on one key.
grep -qF 'sub/deep/two.md' "$RSTATE" || fail "recursion: state not keyed by relative path"$'\n'"$(cat "$RSTATE")"
# Link text carries the path, never the bare basename — see the collision test
# below. No .obsidian ancestor here, so the target is folder-relative.
grep -qF -- '- [[two]]' "$RIDX" && fail "recursion: link written as bare basename"

# settled: a second apply is a no-op
vault_index_apply "$R" "$RIDX" >/dev/null
[ -z "$(vault_index_plan "$R" "$RIDX")" ] || fail "recursion: not idempotent"$'\n'"$(vault_index_plan "$R" "$RIDX")"

# --- has_link matches a path-form link, so apply does not duplicate ----------
# A hand-written INDEX links [[Vault/sub/note]]; matching only the basename
# form re-appended a duplicate (observed on a real 106-note index).
P="$TMP/PathForm"; mkdir -p "$P/sub"
PIDX="$P/INDEX.md"
printf '# PathForm Index\n- [[PathForm/sub/note]]\n' > "$PIDX"
printf 'note\n' > "$P/sub/note.md"
vault_index_apply "$P" "$PIDX" >/dev/null
[ "$(grep -cF -- '- [[' "$PIDX")" = "1" ] || fail "path-form link was duplicated"$'\n'"$(cat "$PIDX")"

# --- a note moved into a subfolder re-keys instead of losing coverage --------
M="$TMP/Moved"; mkdir -p "$M"
MIDX="$M/INDEX.md"; printf '# Moved Index\n' > "$MIDX"
printf 'mover\n' > "$M/mover.md"
vault_index_apply "$M" "$MIDX" >/dev/null
MSTATE="$(index_state_file "$MIDX")"
grep -qxF -- 'mover.md' <(cut -f1 "$MSTATE" | grep -v '^#') || fail "moved: not tracked before move"
mkdir -p "$M/bucket" && mv "$M/mover.md" "$M/bucket/mover.md"
vault_index_apply "$M" "$MIDX" >/dev/null
grep -qF 'bucket/mover.md' "$MSTATE" || fail "moved: not re-keyed to new path"$'\n'"$(cat "$MSTATE")"
[ "$(grep -vc '^#' "$MSTATE")" = "1" ] || fail "moved: stale key left behind"$'\n'"$(cat "$MSTATE")"
[ "$(grep -cF -- '- [[' "$MIDX")" = "1" ] || fail "moved: link duplicated after move"$'\n'"$(cat "$MIDX")"

# --- basename collisions across subfolders each get their own link -----------
# Sibling subfolders routinely hold same-named notes (12 INDEX.md, 5 different
# 2026-05-31.md under Projects/Development). Matching or writing the bare
# basename made the first link satisfy every namesake, so the rest were dropped
# while state still claimed them: 1001 links for 1061 notes, permanent, because
# a hashed note never replans as an ADD.
C="$TMP/Collide"; mkdir -p "$C/a" "$C/b" "$C/c/deep"
CIDX="$C/INDEX.md"; printf '# Collide Index\n' > "$CIDX"
for d in a b c/deep; do printf 'dated\n' > "$C/$d/2026-05-31.md"; done
vault_index_apply "$C" "$CIDX" >/dev/null 2>"$TMP/collide.err"
CSTATE="$(index_state_file "$CIDX")"
[ "$(grep -vc '^#' "$CSTATE")" = "3" ] || fail "collide: expected 3 tracked"$'\n'"$(cat "$CSTATE")"
[ "$(grep -cF -- '- [[' "$CIDX")" = "3" ] \
  || fail "collide: namesakes collapsed to $(grep -cF -- '- [[' "$CIDX") link(s)"$'\n'"$(cat "$CIDX")"
for d in a b c/deep; do
  grep -qxF -- "- [[$d/2026-05-31]]" "$CIDX" || fail "collide: no distinct link for $d"$'\n'"$(cat "$CIDX")"
done
[ -s "$TMP/collide.err" ] && fail "collide: coverage defect reported"$'\n'"$(cat "$TMP/collide.err")"
vault_index_apply "$C" "$CIDX" >/dev/null 2>&1
[ "$(grep -cF -- '- [[' "$CIDX")" = "3" ] || fail "collide: second apply duplicated links"$'\n'"$(cat "$CIDX")"

# --- a legacy bare link does not satisfy its namesakes -----------------------
# The real repair path: an INDEX written by the leaf-matching version already
# holds a bare [[2026-05-31]] standing in for several notes. Each namesake must
# still earn its own path link, or the folder stays stuck at the old coverage.
L="$TMP/Legacy"; mkdir -p "$L/a" "$L/b"
LIDX="$L/INDEX.md"; printf '# Legacy Index\n- [[2026-05-31]]\n' > "$LIDX"
for d in a b; do printf 'dated\n' > "$L/$d/2026-05-31.md"; done
vault_index_apply "$L" "$LIDX" >/dev/null 2>&1
for d in a b; do
  grep -qxF -- "- [[$d/2026-05-31]]" "$LIDX" \
    || fail "legacy: bare link absorbed $d/2026-05-31"$'\n'"$(cat "$LIDX")"
done

# --- a legacy bare link IS honored when the basename is unique ---------------
# Same shape, one note: the bare form is unambiguous and Obsidian resolves it
# vault-wide, so re-linking it would just duplicate the entry. This is also the
# moved-note case (root [[mover]] -> bucket/mover).
U="$TMP/Unique"; mkdir -p "$U/a"
UIDX="$U/INDEX.md"; printf '# Unique Index\n- [[solo]]\n' > "$UIDX"
printf 'solo\n' > "$U/a/solo.md"
vault_index_apply "$U" "$UIDX" >/dev/null 2>&1
[ "$(grep -cF -- '- [[' "$UIDX")" = "1" ] \
  || fail "unique: bare link duplicated"$'\n'"$(cat "$UIDX")"

# --- link target is vault-root-relative when inside a vault ------------------
# Obsidian resolves a slashed target against the vault root, so a
# folder-relative [[sub/note]] would not resolve from an INDEX below the root.
V="$TMP/Vault"; mkdir -p "$V/.obsidian" "$V/Proj/sub"
VIDX="$V/Proj/INDEX.md"
printf 'note\n' > "$V/Proj/sub/note.md"; printf 'flat\n' > "$V/Proj/flat.md"
vault_index_apply "$V/Proj" "$VIDX" >/dev/null
grep -qxF -- '- [[Proj/sub/note]]' "$VIDX" || fail "vault-relative: nested target wrong"$'\n'"$(cat "$VIDX")"
grep -qxF -- '- [[Proj/flat]]'     "$VIDX" || fail "vault-relative: root target wrong"$'\n'"$(cat "$VIDX")"

printf 'ok   vault-index-links.sh (recursion + collisions + vault-relative targets + move re-key)\n'
