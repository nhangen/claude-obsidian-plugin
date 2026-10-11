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

# 10. option without a value fails with the script's own message
ERR="$("$SCRIPT" list --vault 2>&1)" && fail "--vault with no value should exit non-zero"
grep -qF -- "--vault requires a value" <<<"$ERR" || fail "missing-value message not shown; got: $ERR"

echo "PASS: vaultkeeper-resolve-quarantine"
