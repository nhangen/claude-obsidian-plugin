#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPER="$ROOT_DIR/scripts/keeper"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-cli-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

V="$TMP/vault"; mkdir -p "$V"
printf '%s\n' '---' 'date: 2026-06-29' '---' '' '# Repo — 2026-06-29' > "$TMP/init.md"
printf 'first body line\nsecond line\n' > "$TMP/body.md"

# 1. create-on-absent with --init-file: header + section + body all present
F="$V/Projects/foo/2026-06-29.md"
bash "$KEEPER" append --vault "$V" --target "Projects/foo/2026-06-29.md" \
  --section '## 14:30 — abc1234' --body-file "$TMP/body.md" --init-file "$TMP/init.md" >/dev/null
[ -f "$F" ] || fail "target not created"
grep -q '^# Repo — 2026-06-29' "$F"  || fail "init header missing"
grep -q '^## 14:30 — abc1234' "$F"   || fail "section heading missing"
grep -q '^first body line'      "$F" || fail "body missing"

# 2. append to existing: header NOT duplicated, both sections present
printf 'next commit body\n' > "$TMP/body2.md"
bash "$KEEPER" append --vault "$V" --target "Projects/foo/2026-06-29.md" \
  --section '## 15:00 — def5678' --body-file "$TMP/body2.md" --init-file "$TMP/init.md" >/dev/null
[ "$(grep -c '^# Repo — 2026-06-29' "$F")" = "1" ] || fail "header duplicated on append"
grep -q '^## 15:00 — def5678' "$F" || fail "second section missing on append"

# 3. create-on-absent WITHOUT --init-file: no header, just the section
printf 'b\n' > "$TMP/b.md"
bash "$KEEPER" append --vault "$V" --target "Notes/x.md" --section '## 09:00 — note' --body-file "$TMP/b.md" >/dev/null
[ -f "$V/Notes/x.md" ]                 || fail "no-init target not created"
grep -q '^## 09:00 — note' "$V/Notes/x.md" || fail "no-init section missing"

# 4. --date resolves to Daily/<date>.md
bash "$KEEPER" append --vault "$V" --date 2026-06-29 --section '## 10:00 — daily' --body-file "$TMP/b.md" >/dev/null
[ -f "$V/Daily/2026-06-29.md" ] || fail "--date did not resolve to Daily/<date>.md"

# 5. default section heading when --section omitted
bash "$KEEPER" append --vault "$V" --target "Notes/y.md" --body-file "$TMP/b.md" >/dev/null
grep -qE '^## [0-9]{2}:[0-9]{2} — entry' "$V/Notes/y.md" || fail "default section heading missing"

# 6. body from stdin when --body-file omitted
printf 'stdin body\n' | bash "$KEEPER" append --vault "$V" --target "Notes/s.md" --section '## s — t' >/dev/null
grep -q '^stdin body' "$V/Notes/s.md" || fail "stdin body not appended"

# --- validation guards (each must exit non-zero) ---

# 7. unknown subcommand
bash "$KEEPER" frobnicate 2>/dev/null && fail "unknown subcommand must fail"

# 8. missing both --target and --date
bash "$KEEPER" append --vault "$V" --section x --body-file "$TMP/b.md" 2>/dev/null && fail "missing target/date must fail"

# 9. both --target and --date
bash "$KEEPER" append --vault "$V" --target a.md --date 2026-06-29 --body-file "$TMP/b.md" 2>/dev/null && fail "both target and date must fail"

# 10. nonexistent vault
bash "$KEEPER" append --vault "$TMP/nope" --target a.md --section x --body-file "$TMP/b.md" 2>/dev/null && fail "nonexistent vault must fail"

# 11. path traversal — must fail AND must not write outside the vault
bash "$KEEPER" append --vault "$V" --target "../escape.md" --section x --body-file "$TMP/b.md" 2>/dev/null && fail "path traversal must fail"
[ -f "$TMP/escape.md" ] && fail "path traversal wrote outside the vault"

# 12. absolute --target rejected
bash "$KEEPER" append --vault "$V" --target "/etc/keeper-escape.md" --section x --body-file "$TMP/b.md" 2>/dev/null && fail "absolute target must fail"

# 13. unknown flag
bash "$KEEPER" append --vault "$V" --target a.md --bogus z 2>/dev/null && fail "unknown flag must fail"

# 14. zsh portability — the CLI must run clean under zsh (no bash-only constructs)
if command -v zsh >/dev/null 2>&1; then
  zsh "$KEEPER" append --vault "$V" --target "Notes/z.md" --section '## z — t' --body-file "$TMP/b.md" >/dev/null 2>"$TMP/zerr" \
    || { cat "$TMP/zerr" >&2; fail "keeper CLI broke under zsh"; }
  grep -q '^## z — t' "$V/Notes/z.md" || fail "zsh keeper append did not write"
fi

echo "PASS: keeper-cli"
