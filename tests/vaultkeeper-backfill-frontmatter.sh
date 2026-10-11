#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/frontmatter.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vk-backfill-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

V="$TMP/vault"
mkdir -p "$V/Inbox" "$V/Projects/Awesome Motive"

SCRIPT="${ROOT_DIR}/scripts/vaultkeeper-backfill-frontmatter.sh"

# Note 1: in root, no frontmatter
printf '# Root Note\n\nbody line 1\n' > "$V/root.md"
# Note 2: in Inbox, no frontmatter
printf '# Inbox Note\n\ninbox body\n' > "$V/Inbox/inbox.md"
# Note 3: in Projects/Awesome Motive, with frontmatter but no tags
cat > "$V/Projects/Awesome Motive/project.md" <<'EOF'
---
title: My Project
type: note
---

# Project Header

project content body
EOF

# Get initial mtime and body content
_get_mtime() {
  if stat -f %m "$1" >/dev/null 2>&1; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

ROOT_MTIME_INIT="$(_get_mtime "$V/root.md")"
ROOT_BODY_INIT="$(cat "$V/root.md")"

# 1. Dry run should NOT change anything
DRY_OUT="$("$SCRIPT" --vault "$V" --dry-run)"
grep -q "\[dry-run\]" <<<"$DRY_OUT" || fail "dry-run should indicate dry-run mode"
[ "$(cat "$V/root.md")" = "$ROOT_BODY_INIT" ] || fail "dry-run modified root.md"
[ "$(_get_mtime "$V/root.md")" = "$ROOT_MTIME_INIT" ] || fail "dry-run touched mtime"

# Sleep briefly so mtime difference would be observable if touch -r wasn't working
sleep 1

# 2. Apply with limit 2
APPLY_OUT="$("$SCRIPT" --vault "$V" --apply --limit 2)"
grep -q "\[applied\]" <<<"$APPLY_OUT" || fail "apply should report applied updates"

# At least one note was updated and limit was respected
UPDATED_COUNT="$(grep -c "\[applied\]" <<<"$APPLY_OUT")"
[ "$UPDATED_COUNT" -eq 2 ] || fail "apply limit 2 was not respected (got $UPDATED_COUNT)"

# 3. Apply to remaining notes
"$SCRIPT" --vault "$V" --apply --limit 10 >/dev/null

# 4. Verify tag inference:
# - root.md should have tag: unfiled
grep -q "tags: \[unfiled\]" "$V/root.md" || fail "root.md did not get unfiled tag: $(cat "$V/root.md")"
# Body of root.md must be preserved byte-identically
grep -qF "body line 1" "$V/root.md" || fail "root.md body was lost"

# - Inbox/inbox.md should have tag: needs-filing
grep -q "tags: \[needs-filing\]" "$V/Inbox/inbox.md" || fail "Inbox note did not get needs-filing tag: $(cat "$V/Inbox/inbox.md")"

# - project.md should have tags: projects, awesome-motive
grep -q "tags: \[projects, awesome-motive\]" "$V/Projects/Awesome Motive/project.md" \
  || fail "project.md did not get kebab-cased tags: $(cat "$V/Projects/Awesome Motive/project.md")"
# Pre-existing frontmatter fields must be preserved
grep -q "title: My Project" "$V/Projects/Awesome Motive/project.md" || fail "existing frontmatter field title lost"
grep -q "type: note" "$V/Projects/Awesome Motive/project.md" || fail "existing frontmatter field type lost"
# Pre-existing body must be preserved
grep -qF "project content body" "$V/Projects/Awesome Motive/project.md" || fail "existing body lost"

# 5. Verify mtime preservation on root.md
ROOT_MTIME_AFTER="$(_get_mtime "$V/root.md")"
[ "$ROOT_MTIME_AFTER" = "$ROOT_MTIME_INIT" ] || fail "mtime was not preserved on root.md (before=$ROOT_MTIME_INIT after=$ROOT_MTIME_AFTER)"

# 6. A malformed note is reported as failed, left byte-identical, leaves no temp file, and does not stop the run;
#    a note's file mode survives the rewrite
_get_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi
}
printf -- '---\ntitle: no closing fence\nbody text\n' > "$V/Unclosed.md"
UNCLOSED_INIT="$(cat "$V/Unclosed.md")"
printf '# Mode Note\n\nmode body\n' > "$V/Mode.md"
chmod 644 "$V/Mode.md"
RC=0
FAIL_OUT="$("$SCRIPT" --vault "$V" --apply --limit 10 2>&1)" || RC=$?
[ "$RC" -ne 0 ] || fail "a note that could not be patched should make the run exit non-zero"
grep -qF "[applied] Unclosed.md" <<<"$FAIL_OUT" && fail "unclosed note reported as applied: $FAIL_OUT"
grep -qF "Unclosed.md" <<<"$FAIL_OUT" || fail "unclosed note not named in the output: $FAIL_OUT"
[ "$(cat "$V/Unclosed.md")" = "$UNCLOSED_INIT" ] || fail "unclosed note was modified"
grep -q "tags: \[unfiled\]" "$V/Mode.md" || fail "one failing note stopped the rest of the batch"
[ "$(_get_mode "$V/Mode.md")" = "644" ] || fail "file mode changed to $(_get_mode "$V/Mode.md")"
[ -z "$(find "$V" -maxdepth 1 -name '.backfill-*')" ] || fail "temp file leaked in the vault root"

# 7. option without a value fails with the script's own message
ERR="$("$SCRIPT" --limit 2>&1)" && fail "--limit with no value should exit non-zero"
grep -qF -- "--limit requires a value" <<<"$ERR" || fail "missing-value message not shown; got: $ERR"

echo "PASS: vaultkeeper-backfill-frontmatter"
