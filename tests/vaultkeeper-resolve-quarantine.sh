#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vk-res-q-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

V="$TMP/vault"
Q="$V/.vaultkeeper-quarantine"
mkdir -p "$Q"

SCRIPT="${ROOT_DIR}/scripts/vaultkeeper-resolve-quarantine.sh"

# 1. list on empty
OUT="$("$SCRIPT" list --vault "$V")"
grep -q "Quarantine is empty" <<<"$OUT" || fail "list should report empty quarantine"

# 2. list with items
echo "item" > "$Q/1700000000-Librarian.sync-conflict-20261010-010101-MBP.md"
OUT="$("$SCRIPT" list --vault "$V")"
grep -q "Quarantined conflicts (1):" <<<"$OUT" || fail "list should show 1 conflict"

# 3. diff
echo "# Live" > "$V/Live.md"
echo "# Conflict" > "$Q/1700000000-Live.sync-conflict-20261010-010101-MBP.md"
DIFF_OUT="$("$SCRIPT" diff 1700000000-Live.sync-conflict-20261010-010101-MBP.md --vault "$V")"
grep -q -- "-# Live" <<<"$DIFF_OUT" || fail "diff should show live note content"
grep -q -- "+# Conflict" <<<"$DIFF_OUT" || fail "diff should show conflict content"

# 4. discard
"$SCRIPT" discard 1700000000-Live.sync-conflict-20261010-010101-MBP.md --vault "$V" >/dev/null
[ ! -f "$Q/1700000000-Live.sync-conflict-20261010-010101-MBP.md" ] || fail "discard should delete quarantine copy"

# 5. merge machine file (discarded)
"$SCRIPT" merge 1700000000-Librarian.sync-conflict-20261010-010101-MBP.md --vault "$V" >/dev/null
[ ! -f "$Q/1700000000-Librarian.sync-conflict-20261010-010101-MBP.md" ] || fail "merge should discard machine-owned file"

# 6. merge Pending.md checklists
cat > "$V/Pending.md" <<'EOF'
- [ ] TASK: existing
- [x] TASK: done
EOF

cat > "$Q/1700000000-Pending.sync-conflict-20261010-010101-MBP.md" <<'EOF'
- [ ] TASK: existing
- [ ] TASK: new item from conflict
- [x] TASK: done
EOF

"$SCRIPT" merge 1700000000-Pending.sync-conflict-20261010-010101-MBP.md --vault "$V" >/dev/null
[ ! -f "$Q/1700000000-Pending.sync-conflict-20261010-010101-MBP.md" ] || fail "merge should remove Pending quarantine copy"
grep -qxF -- "- [ ] TASK: new item from conflict" "$V/Pending.md" || fail "missing task not merged into Pending.md"
[ "$(grep -F -c -- "- [ ] TASK: existing" "$V/Pending.md")" -eq 1 ] || fail "duplicate task introduced in Pending.md"

# 7. merge: unterminated last line is merged, and Pending.md without a trailing newline stays line-separated
printf -- '- [ ] a' > "$V/Pending.md"
QF="1700000001-Pending.sync-conflict-20261010-020202-MBP.md"
printf -- '- [x] foo bar\n- [ ] last' > "$Q/$QF"
"$SCRIPT" merge "$QF" --vault "$V" >/dev/null
grep -qxF -- "- [ ] a" "$V/Pending.md" || fail "append glued onto an unterminated Pending.md line"
grep -qxF -- "- [x] foo bar" "$V/Pending.md" || fail "first conflict item not merged"
grep -qxF -- "- [ ] last" "$V/Pending.md" || fail "unterminated last conflict line was dropped"
[ ! -f "$Q/$QF" ] || fail "fully merged copy should be removed"

# 8. merge: a copy with content that cannot be merged is kept, and the skipped lines are reported
printf -- '- [ ] a\n' > "$V/Pending.md"
QF="1700000002-Pending.sync-conflict-20261010-030303-MBP.md"
printf -- '# Hand notes\n- [ ] kept item\n' > "$Q/$QF"
if ERR="$("$SCRIPT" merge "$QF" --vault "$V" 2>&1 >/dev/null)"; then fail "merge with unmergeable lines should exit non-zero"; fi
[ -f "$Q/$QF" ] || fail "quarantine copy with unmerged content was deleted"
grep -qxF -- "- [ ] kept item" "$V/Pending.md" || fail "mergeable item was not merged"
grep -qF -- "# Hand notes" <<<"$ERR" || fail "skipped line not reported; got: $ERR"
rm -f "$Q/$QF"

# 9. merge: Pending.md is written under the keeper lock
printf -- '- [ ] a\n' > "$V/Pending.md"
QF="1700000003-Pending.sync-conflict-20261010-040404-MBP.md"
printf -- '- [ ] locked out\n' > "$Q/$QF"
(
  . "$ROOT_DIR/scripts/lib/note-hash.sh"
  LOCK="$(keeper_lock_acquire "$(cd "$V" && pwd -P)")" || exit 9
  if KEEPER_LOCK_TIMEOUT_SECONDS=1 "$SCRIPT" merge "$QF" --vault "$V" >/dev/null 2>&1; then
    keeper_lock_release "$LOCK"; exit 8
  fi
  keeper_lock_release "$LOCK"
) || fail "merge ran while the keeper lock was held (rc=$?)"
[ -f "$Q/$QF" ] || fail "copy removed although the lock was never acquired"
grep -qF -- "locked out" "$V/Pending.md" && fail "Pending.md written without the lock"
rm -f "$Q/$QF"
[ -z "$(find "$V" -maxdepth 1 -name '.Pending-*')" ] || fail "temp file leaked in the vault root"

# 11. a conflict copy whose extra lines are already in the live file merges cleanly, and Pending.md keeps its mode
printf -- '# Pending\n- [ ] a\n' > "$V/Pending.md"; chmod 644 "$V/Pending.md"
QF="1700000004-Pending.sync-conflict-20261010-050505-MBP.md"
printf -- '# Pending\n- [ ] a\n- [ ] b\n' > "$Q/$QF"
"$SCRIPT" merge "$QF" --vault "$V" >/dev/null || fail "heading already present in Pending.md should not block the merge"
[ ! -f "$Q/$QF" ] || fail "fully covered copy should be removed"
grep -qxF -- "- [ ] b" "$V/Pending.md" || fail "item b not merged"
MODE="$(stat -c %a "$V/Pending.md" 2>/dev/null || stat -f %Lp "$V/Pending.md")"
[ "$MODE" = "644" ] || fail "Pending.md mode changed to $MODE"

# 10. option without a value fails with the script's own message
ERR="$("$SCRIPT" list --vault 2>&1)" && fail "--vault with no value should exit non-zero"
grep -qF -- "--vault requires a value" <<<"$ERR" || fail "missing-value message not shown; got: $ERR"

# 12. diff: an unreadable folder elsewhere in the vault does not hide the nested live note
rm -f "$V/Live.md"
mkdir -p "$V/Notes" "$V/Locked"
echo "# Nested live" > "$V/Notes/Nested.md"
QF="1700000005-Nested.sync-conflict-20261010-060606-MBP.md"
echo "# Nested conflict" > "$Q/$QF"
chmod 000 "$V/Locked"
DIFF_OUT="$("$SCRIPT" diff "$QF" --vault "$V" 2>/dev/null)" || true
chmod 755 "$V/Locked"
grep -q -- "^--- live: .*/Notes/Nested.md$" <<<"$DIFF_OUT" || fail "unreadable folder hid the nested live note; got: $DIFF_OUT"
rm -f "$Q/$QF"

# 13. diff: a vault-root note wins a stem collision, and the collision is reported
echo "# Root dup" > "$V/Dup.md"
mkdir -p "$V/A"; echo "# A dup" > "$V/A/Dup.md"
QF="1700000006-Dup.sync-conflict-20261010-070707-MBP.md"
echo "# Dup conflict" > "$Q/$QF"
DIFF_ERR="$TMP/dup.err"
DIFF_OUT="$("$SCRIPT" diff "$QF" --vault "$V" 2>"$DIFF_ERR")"
grep -q -- "^--- live: .*/vault/Dup.md$" <<<"$DIFF_OUT" || fail "root note should win the stem collision; got: $DIFF_OUT"
grep -qF -- "2 notes named Dup.md" "$DIFF_ERR" || fail "root-wins collision not warned; got: $(cat "$DIFF_ERR")"

# 14. diff: with no root note, the nested pick is deterministic and warned
rm -f "$V/Dup.md"
mkdir -p "$V/Z"; echo "# Z dup" > "$V/Z/Dup.md"
DIFF_OUT="$("$SCRIPT" diff "$QF" --vault "$V" 2>"$DIFF_ERR")"
grep -q -- "^--- live: .*/vault/A/Dup.md$" <<<"$DIFF_OUT" || fail "nested pick should be the sorted first match; got: $DIFF_OUT"
grep -qF -- "2 notes named Dup.md" "$DIFF_ERR" || fail "nested collision not warned; got: $(cat "$DIFF_ERR")"
rm -f "$Q/$QF"

# 15. merge: when Pending.md's mode cannot be read, the merge stops and keeps the copy
REAL_STAT="$(command -v stat)"
mkdir -p "$TMP/stub"
cat > "$TMP/stub/stat" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *%a*|*%Lp*) exit 1 ;;
  *) exec "$REAL_STAT" "\$@" ;;
esac
STUB
chmod +x "$TMP/stub/stat"
printf -- '- [ ] a\n' > "$V/Pending.md"; chmod 644 "$V/Pending.md"
QF="1700000007-Pending.sync-conflict-20261010-080808-MBP.md"
printf -- '- [ ] mode probe\n' > "$Q/$QF"
if ERR="$(PATH="$TMP/stub:$PATH" "$SCRIPT" merge "$QF" --vault "$V" 2>&1 >/dev/null)"; then
  fail "merge should fail when Pending.md's mode cannot be read"
fi
[ -f "$Q/$QF" ] || fail "quarantine copy deleted although the merge was not applied"
grep -qF -- "mode probe" "$V/Pending.md" && fail "Pending.md swapped without its mode"
grep -qF -- "could not read mode" <<<"$ERR" || fail "mode failure not reported; got: $ERR"
rm -f "$Q/$QF"

# 16. discard with symlinked quarantine parent refuses and leaves outside sentinel byte-identical
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE" "$TMP/outside-baseline"
SENTINEL_DISCARD="1700000010-Live.sync-conflict-20261010-090909-MBP.md"
printf 'outside live sentinel content\n' > "$OUTSIDE/$SENTINEL_DISCARD"
cp "$OUTSIDE/$SENTINEL_DISCARD" "$TMP/outside-baseline/$SENTINEL_DISCARD"

V_SYM="$TMP/vault-sym"
mkdir -p "$V_SYM"
ln -s "$OUTSIDE" "$V_SYM/.vaultkeeper-quarantine"

if ERR="$("$SCRIPT" discard "$SENTINEL_DISCARD" --vault "$V_SYM" 2>&1)"; then
  fail "discard should refuse symlinked quarantine parent"
fi
grep -qF -- "refusing symlink" <<<"$ERR" || fail "discard did not report refusing symlink; got: $ERR"
cmp -s "$OUTSIDE/$SENTINEL_DISCARD" "$TMP/outside-baseline/$SENTINEL_DISCARD" || fail "outside sentinel modified by discard"

# 17. machine-owned merge with symlinked quarantine parent refuses and leaves outside sentinel byte-identical
SENTINEL_LIBRARIAN="1700000011-Librarian.sync-conflict-20261010-101010-MBP.md"
printf 'outside librarian sentinel content\n' > "$OUTSIDE/$SENTINEL_LIBRARIAN"
cp "$OUTSIDE/$SENTINEL_LIBRARIAN" "$TMP/outside-baseline/$SENTINEL_LIBRARIAN"

if ERR="$("$SCRIPT" merge "$SENTINEL_LIBRARIAN" --vault "$V_SYM" 2>&1)"; then
  fail "machine-owned merge should refuse symlinked quarantine parent"
fi
grep -qF -- "refusing symlink" <<<"$ERR" || fail "machine-owned merge did not report refusing symlink; got: $ERR"
cmp -s "$OUTSIDE/$SENTINEL_LIBRARIAN" "$TMP/outside-baseline/$SENTINEL_LIBRARIAN" || fail "outside sentinel modified by machine-owned merge"

# 18. Pending merge with symlinked quarantine parent refuses and leaves outside sentinel and Pending.md byte-identical
SENTINEL_PENDING="1700000012-Pending.sync-conflict-20261010-111111-MBP.md"
printf -- '- [ ] outside task\n' > "$OUTSIDE/$SENTINEL_PENDING"
cp "$OUTSIDE/$SENTINEL_PENDING" "$TMP/outside-baseline/$SENTINEL_PENDING"
printf -- '- [ ] vault task\n' > "$V_SYM/Pending.md"
cp "$V_SYM/Pending.md" "$TMP/outside-baseline/Pending.md"

if ERR="$("$SCRIPT" merge "$SENTINEL_PENDING" --vault "$V_SYM" 2>&1)"; then
  fail "Pending merge should refuse symlinked quarantine parent"
fi
grep -qF -- "refusing symlink" <<<"$ERR" || fail "Pending merge did not report refusing symlink; got: $ERR"
cmp -s "$OUTSIDE/$SENTINEL_PENDING" "$TMP/outside-baseline/$SENTINEL_PENDING" || fail "outside sentinel modified by Pending merge"
cmp -s "$V_SYM/Pending.md" "$TMP/outside-baseline/Pending.md" || fail "Pending.md modified by refused Pending merge"

# 19. diff and list with symlinked quarantine parent refuse and exit non-zero
if ERR="$("$SCRIPT" diff "$SENTINEL_DISCARD" --vault "$V_SYM" 2>&1)"; then
  fail "diff should refuse symlinked quarantine parent"
fi
grep -qF -- "refusing symlink" <<<"$ERR" || fail "diff did not report refusing symlink; got: $ERR"

if ERR="$("$SCRIPT" list --vault "$V_SYM" 2>&1)"; then
  fail "list should refuse symlinked quarantine parent"
fi
grep -qF -- "refusing symlink" <<<"$ERR" || fail "list did not report refusing symlink; got: $ERR"

# 20. discard and machine-owned merge are performed under the keeper lock
QF_DISCARD="1700000020-Live.sync-conflict-20261010-121212-MBP.md"
printf 'lock test discard\n' > "$Q/$QF_DISCARD"
(
  . "$ROOT_DIR/scripts/lib/note-hash.sh"
  LOCK="$(keeper_lock_acquire "$(cd "$V" && pwd -P)")" || exit 9
  if KEEPER_LOCK_TIMEOUT_SECONDS=1 "$SCRIPT" discard "$QF_DISCARD" --vault "$V" >/dev/null 2>&1; then
    keeper_lock_release "$LOCK"; exit 8
  fi
  keeper_lock_release "$LOCK"
) || fail "discard ran while the keeper lock was held (rc=$?)"
[ -f "$Q/$QF_DISCARD" ] || fail "discard removed file although the lock was held"
rm -f "$Q/$QF_DISCARD"

QF_MACHINE="1700000021-Librarian.sync-conflict-20261010-131313-MBP.md"
printf 'lock test librarian\n' > "$Q/$QF_MACHINE"
(
  . "$ROOT_DIR/scripts/lib/note-hash.sh"
  LOCK="$(keeper_lock_acquire "$(cd "$V" && pwd -P)")" || exit 9
  if KEEPER_LOCK_TIMEOUT_SECONDS=1 "$SCRIPT" merge "$QF_MACHINE" --vault "$V" >/dev/null 2>&1; then
    keeper_lock_release "$LOCK"; exit 8
  fi
  keeper_lock_release "$LOCK"
) || fail "machine merge ran while the keeper lock was held (rc=$?)"
[ -f "$Q/$QF_MACHINE" ] || fail "machine merge removed file although the lock was held"
rm -f "$Q/$QF_MACHINE"

# 21. target paths prefixed with .vaultkeeper-quarantine/ or absolute path resolve; traversal is refused
QF_PREFIX="1700000022-Live.sync-conflict-20261010-141414-MBP.md"
printf 'prefix test\n' > "$Q/$QF_PREFIX"
"$SCRIPT" diff ".vaultkeeper-quarantine/$QF_PREFIX" --vault "$V" >/dev/null || fail "prefixed target failed to resolve"
"$SCRIPT" diff "$V/.vaultkeeper-quarantine/$QF_PREFIX" --vault "$V" >/dev/null || fail "absolute target failed to resolve"
if "$SCRIPT" diff "../outside/sentinel" --vault "$V" >/dev/null 2>&1; then
  fail "path traversal target should be refused"
fi
rm -f "$Q/$QF_PREFIX"

# 22. leaf symlinks are refused
QF_LEAF_SYM="1700000023-Live.sync-conflict-20261010-151515-MBP.md"
ln -s "$V/Pending.md" "$Q/$QF_LEAF_SYM"
if ERR="$("$SCRIPT" discard "$QF_LEAF_SYM" --vault "$V" 2>&1)"; then
  fail "discard should refuse leaf symlink"
fi
grep -qF -- "refusing symlink" <<<"$ERR" || fail "leaf symlink refusal message missing; got: $ERR"
[ -L "$Q/$QF_LEAF_SYM" ] || fail "leaf symlink was removed"
rm -f "$Q/$QF_LEAF_SYM"

# 23. diff refuses a live note that is a symlink and reads nothing through it
QF_LIVE_SYM="1700000024-LiveLink.sync-conflict-20261010-161616-MBP.md"
printf 'conflict body\n' > "$Q/$QF_LIVE_SYM"
printf 'outside live content\n' > "$TMP/outside-live.md"
ln -s "$TMP/outside-live.md" "$V/LiveLink.md"
if ERR="$("$SCRIPT" diff "$QF_LIVE_SYM" --vault "$V" 2>&1)"; then
  fail "diff should refuse a symlinked live note"
fi
grep -qE -- "refusing symlink .*/vault/LiveLink\.md$" <<<"$ERR" || fail "live symlink refusal message missing; got: $ERR"
grep -qF -- "outside live content" <<<"$ERR" && fail "diff leaked content through the live symlink"
rm -f "$Q/$QF_LIVE_SYM" "$V/LiveLink.md"

# 24. an absolute path outside the quarantine is refused with a containment message
printf 'elsewhere\n' > "$V/elsewhere.md"
if ERR="$("$SCRIPT" discard "$V/elsewhere.md" --vault "$V" 2>&1)"; then
  fail "discard should refuse an absolute path outside the quarantine"
fi
grep -qF -- "refusing path outside .vaultkeeper-quarantine" <<<"$ERR" || fail "outside-path refusal message missing; got: $ERR"
[ -f "$V/elsewhere.md" ] || fail "file outside the quarantine was removed"
rm -f "$V/elsewhere.md"

echo "PASS: vaultkeeper-resolve-quarantine"
