#!/usr/bin/env bash
# Resolved keeper-save writes must be one direct keeper call, never a librarian
# dispatch (#223). Guidance is asserted on the skill text; the write path on a
# mock vault.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPER="$ROOT_DIR/scripts/keeper"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-save-direct-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"

SKILL="$ROOT_DIR/skills/keeper-save/SKILL.md"
DESC="$(sed -n '/^description:/p' "$SKILL")"
case "$DESC" in
  *"directly"*"no subagent"*"unresolved INSERT dispatches"*) ;;
  *) fail "keeper-save description must say resolved writes are direct and only unresolved INSERT dispatches the librarian" ;;
esac
grep -q 'Fully specified writes never spawn a model' "$SKILL" || fail "keeper-save lacks the fast-path-default statement"
grep -q 'do not also' "$SKILL" || fail "keeper-save must forbid keeper+MCP double write"
grep -q 'never assume they are' "$SKILL" || fail "keeper-save must not assume MCP tools exist"
grep -qiE 'owns target resolution' "$ROOT_DIR/skills/daily-note/SKILL.md" \
  && fail "daily-note still routes append through the librarian"
grep -q 'Do not dispatch the vault-librarian' "$ROOT_DIR/skills/daily-note/SKILL.md" \
  || fail "daily-note must say append needs no librarian"
grep -q 'only for a page inside an existing project' "$ROOT_DIR/skills/create-note/SKILL.md" \
  || fail "create-note must scope resolved: true to a validated existing-project path"
grep -q 'allowlist_validate' "$ROOT_DIR/skills/create-note/SKILL.md" || fail "create-note lost allow-list validation"
tr '\n' ' ' < "$ROOT_DIR/README.md" | grep -q 'should not dispatch the librarian directly' \
  || fail "README must say resolved writes skip the librarian"
grep -q -- '--skip-if-hash "<hash>"' "$SKILL" || fail "keeper-save append template must carry --skip-if-hash"
grep -q 'no .target. is not resolved' "$SKILL" || fail "resolved insert without target must fall back to the librarian"
grep -q 'Already-resolved writes skip this skill' "$ROOT_DIR/skills/ask/SKILL.md" \
  || fail "ask skill must redirect resolved writes to keeper-save"

V="$TMP/vault"; mkdir -p "$V/.obsidian" "$V/Decisions"
printf 'body line\n' > "$TMP/body.md"

# resolved insert: one note, no second copy, hash-independent
bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-10-18-x.md" \
  --body-file "$TMP/body.md" --title "2026-10-18-x" >/dev/null
[ -f "$V/Decisions/2026-10-18-x.md" ] || fail "resolved insert wrote nothing"
grep -q 'body line' "$V/Decisions/2026-10-18-x.md" || fail "insert body missing (readback)"
[ "$(find "$V" -name '*2026-10-18-x*' -type f | wc -l | tr -d ' ')" = 1 ] || fail "insert wrote more than one file"

# append with hash guard: first write lands, replay is a no-op
bash "$KEEPER" append --vault "$V" --date 2026-10-18 --section '## 10:00 — cap abc1234' \
  --body-file "$TMP/body.md" --skip-if-hash abc1234 >/dev/null
bash "$KEEPER" append --vault "$V" --date 2026-10-18 --section '## 10:00 — cap abc1234' \
  --body-file "$TMP/body.md" --skip-if-hash abc1234 >/dev/null
[ "$(grep -c 'abc1234' "$V/Daily/2026-10-18.md")" = 1 ] || fail "hash guard did not dedup replay"

# a second insert to the same target is refused and leaves the first intact
if bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-10-18-x.md" \
    --body-file "$TMP/body.md" --title "2026-10-18-x" >/dev/null 2>"$TMP/dup.err"; then
  fail "insert onto an existing target exited 0"
fi
[ -s "$TMP/dup.err" ] || fail "collision refusal printed nothing"
[ "$(grep -c 'body line' "$V/Decisions/2026-10-18-x.md")" = 1 ] || fail "collision altered the original note"

# failure is reported, not swallowed
if bash "$KEEPER" append --vault "$TMP/missing" --date 2026-10-18 --body-file "$TMP/body.md" >/dev/null 2>&1; then
  fail "keeper exited 0 on a missing vault"
fi
MISSING_ERR="$(bash "$KEEPER" append --vault "$TMP/missing" --date 2026-10-18 --body-file "$TMP/body.md" 2>&1 >/dev/null || true)"
[ -n "$MISSING_ERR" ] || fail "missing-vault failure printed no message"
echo "PASS: keeper-save-direct-routing"
