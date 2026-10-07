#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-apply-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
F="$TMP/Decisions"; mkdir -p "$F"
IDX="$F/INDEX.md"; printf '# Decisions Index\n' > "$IDX"
IDX_BEFORE="$(cat "$IDX")"
printf 'note A\n' > "$F/a.md"
printf 'note B\n' > "$F/b.md"
STATE="$(index_state_file "$IDX")"

OUTSIDE_IDX="$TMP/outside-INDEX.md"
if vault_index_apply "$TMP" "$F" "$OUTSIDE_IDX" >/dev/null 2>&1; then
  fail "vault_index_apply accepted an INDEX outside its indexed folder"
fi
[ ! -e "$OUTSIDE_IDX" ] || fail "vault_index_apply wrote outside its indexed folder"

mkdir -p "$TMP/configured-vault" "$TMP/outside-vault"
if vault_index_apply "$TMP/configured-vault" "$TMP/outside-vault" "$TMP/outside-vault/INDEX.md" >/dev/null 2>&1; then
  fail "vault_index_apply accepted a folder outside the configured vault"
fi
[ ! -e "$TMP/outside-vault/INDEX.md" ] || fail "vault_index_apply escaped the configured vault"
ln -s "$TMP/outside-vault" "$TMP/configured-vault/escape"
if vault_index_apply "$TMP/configured-vault" "$TMP/configured-vault/escape" "$TMP/configured-vault/escape/INDEX.md" >/dev/null 2>&1; then
  fail "vault_index_apply accepted a symlink escape from the configured vault"
fi
[ ! -e "$TMP/outside-vault/INDEX.md" ] || fail "vault_index_apply wrote through a symlink escape"

# Cold start: no state -> both notes are ADD.
ADDED="$(vault_index_apply "$TMP" "$F" "$IDX")"
grep -qxF "a.md" <<<"$ADDED" || fail "expected a.md in ADD output"
grep -qxF "b.md" <<<"$ADDED" || fail "expected b.md in ADD output"
[ -f "$STATE" ] || fail "state file not created"
grep -q '^# last_reconciled:[0-9]\+$' "$STATE" || fail "no last_reconciled stamp"
note_hash_valid "$(state_hash_for "$STATE" "a.md")" || fail "a.md hash not stored validly"

# apply owns the link write (#30) but must only ever append: the prior content
# stays byte-identical at the top of the file. See tests/vault-index-links.sh
# for the link/coverage contract itself.
[ "$(head -c ${#IDX_BEFORE} "$IDX")" = "$IDX_BEFORE" ] || fail "apply must not rewrite existing INDEX.md content"

# Idempotent: second apply with no changes -> empty plan, no new ADD.
# Use explicit timestamps instead of sleep to avoid wall-clock dependency.
touch -t 202001010000 "$F/a.md" "$F/b.md"
ADDED2="$(vault_index_apply "$TMP" "$F" "$IDX")"
[ -z "$ADDED2" ] || fail "second apply should add nothing, got: $ADDED2"
PLAN="$(vault_index_plan "$F" "$IDX")"
[ -z "$PLAN" ] || fail "plan should be empty after apply, got: $PLAN"

# DROP: delete a note, apply -> state entry removed.
rm "$F/b.md"
vault_index_apply "$TMP" "$F" "$IDX" >/dev/null
[ -z "$(state_hash_for "$STATE" "b.md")" ] || fail "b.md should be dropped from state"

# Substring collision regression: b.md must survive when only b.md.md changes.
TMP2="$(mktemp -d "${TMPDIR:-/tmp}/vault-apply-substr-XXXXXX")"; trap 'rm -rf "$TMP2"' EXIT
F2="$TMP2/Decisions"; mkdir -p "$F2"
IDX2="$F2/INDEX.md"; printf '# Decisions Index\n' > "$IDX2"
printf 'content-b\n'      > "$F2/b.md"
printf 'content-bdouble\n' > "$F2/b.md.md"
STATE2="$(index_state_file "$IDX2")"

# First apply: seeds both entries.
vault_index_apply "$TMP2" "$F2" "$IDX2" >/dev/null
note_hash_valid "$(state_hash_for "$STATE2" "b.md")"    || fail "setup: b.md hash missing"
note_hash_valid "$(state_hash_for "$STATE2" "b.md.md")" || fail "setup: b.md.md hash missing"

# Change only b.md.md, leave b.md at old timestamp.
touch -t 197001010000 "$F2/b.md"
printf 'content-bdouble-changed\n' > "$F2/b.md.md"

# Apply again: plan touches b.md.md (CHANGED), not b.md.
vault_index_apply "$TMP2" "$F2" "$IDX2" >/dev/null

# b.md's state entry must still exist.
note_hash_valid "$(state_hash_for "$STATE2" "b.md")" \
  || fail "substring regression: b.md state entry was wrongly dropped when b.md.md changed"

# Unreadable file: chmod 000 -> apply must NOT create a malformed state entry.
TMP3="$(mktemp -d "${TMPDIR:-/tmp}/vault-apply-unreadable-XXXXXX")"; trap 'rm -rf "$TMP3"' EXIT
F3="$TMP3/Notes"; mkdir -p "$F3"
IDX3="$F3/INDEX.md"; printf '# Notes Index\n' > "$IDX3"
printf 'readable content\n' > "$F3/good.md"
printf 'secret content\n'   > "$F3/unreadable.md"
STATE3="$(index_state_file "$IDX3")"

# Make unreadable.md unreadable before the first apply.
chmod 000 "$F3/unreadable.md"
WARN="$(vault_index_apply "$TMP3" "$F3" "$IDX3" 2>&1 >/dev/null)" || true
# Restore perms immediately so trap cleanup works.
chmod 644 "$F3/unreadable.md"

# good.md should be present with a valid hash; unreadable.md should be absent.
note_hash_valid "$(state_hash_for "$STATE3" "good.md")" \
  || fail "unreadable test: good.md hash should be valid"
STORED_UNREAD="$(state_hash_for "$STATE3" "unreadable.md")"
[ -z "$STORED_UNREAD" ] || note_hash_valid "$STORED_UNREAD" \
  || fail "unreadable file produced malformed state entry: $STORED_UNREAD"

# Invariant: with a backslash in the folder path, apply links and hashes every
# note; it never reports success over an INDEX it did not write.
TMP4="$(mktemp -d "${TMPDIR:-/tmp}/vault-apply-backslash-XXXXXX")"; trap 'rm -rf "$TMP4"' EXIT
F4="$TMP4/Pro\\tjects"; mkdir -p "$F4"
printf 'one\n' > "$F4/one.md"
ADDED4="$(vault_index_apply "$TMP4" "$F4" "$F4/INDEX.md")"
[ "$ADDED4" = "one.md" ] || fail "backslash folder: expected one.md added, got: $ADDED4"
grep -qxF -- '- [[one]]' "$F4/INDEX.md" || fail "backslash folder: INDEX link missing"$'\n'"$(cat "$F4/INDEX.md" 2>/dev/null)"
note_hash_valid "$(state_hash_for "$(index_state_file "$F4/INDEX.md")" "one.md")" || fail "backslash folder: hash not stored validly"

# --- zsh portability ---------------------------------------------------------
# The lib is also sourced into zsh (the librarian/keeper runtime). There a
# `trap ... RETURN` prints "undefined signal: RETURN", and a variable named
# `path` (tied to PATH) makes every external command fail. Run plan and apply
# natively under zsh and require a clean, complete result.
if command -v zsh >/dev/null 2>&1; then
  ZT="$(mktemp -d "${TMPDIR:-/tmp}/vault-zsh-XXXXXX")"
  ZF="$ZT/Z"; mkdir -p "$ZF/sub"; printf '# Z Index\n' > "$ZF/INDEX.md"
  printf 'zsh note\n' > "$ZF/z.md"; printf 'deep\n' > "$ZF/sub/deep.md"
  # The zsh snippets passed to run_zsh are single-quoted on purpose: zsh,
  # not this shell, expands them.
  run_zsh() {
    ROOT_DIR="$ROOT_DIR" ZT="$ZT" ZF="$ZF" zsh -c '
      . "$ROOT_DIR/scripts/lib/note-hash.sh"
      . "$ROOT_DIR/scripts/lib/vault-index.sh"
      '"$1" 2>"$ZT/err"
  }
  # shellcheck disable=SC2016
  ZPLAN="$(run_zsh 'vault_index_plan "$ZF" "$ZF/INDEX.md"')" || fail "plan failed under zsh: $(cat "$ZT/err")"
  [ ! -s "$ZT/err" ] || fail "plan wrote stderr under zsh: $(cat "$ZT/err")"
  [ "$ZPLAN" = "$(vault_index_plan "$ZF" "$ZF/INDEX.md")" ] || fail "plan differs under zsh:"$'\n'"$ZPLAN"
  [ "$ZPLAN" = "ADD"$'\t'"sub/deep.md"$'\n'"ADD"$'\t'"z.md" ] || fail "unexpected zsh plan:"$'\n'"$ZPLAN"
  # shellcheck disable=SC2016
  ZADDED="$(run_zsh 'vault_index_apply "$ZT" "$ZF" "$ZF/INDEX.md"')" || fail "apply failed under zsh: $(cat "$ZT/err")"
  [ ! -s "$ZT/err" ] || fail "apply wrote stderr under zsh: $(cat "$ZT/err")"
  [ "$ZADDED" = "sub/deep.md"$'\n'"z.md" ] || fail "apply under zsh reported: $ZADDED"
  grep -qxF -- '- [[z]]' "$ZF/INDEX.md" || fail "apply under zsh did not link z.md"$'\n'"$(cat "$ZF/INDEX.md")"
  grep -qxF -- '- [[sub/deep]]' "$ZF/INDEX.md" || fail "apply under zsh did not link sub/deep.md"
  note_hash_valid "$(state_hash_for "$(index_state_file "$ZF/INDEX.md")" "z.md")" || fail "apply under zsh stored no valid hash"
  # shellcheck disable=SC2016
  [ -z "$(run_zsh 'vault_index_plan "$ZF" "$ZF/INDEX.md"')" ] || fail "plan under zsh not empty after apply"
  rm -rf "$ZT"
fi

echo "PASS: vault-index-apply"
