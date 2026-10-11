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

echo "PASS: vaultkeeper-resolve-quarantine"
