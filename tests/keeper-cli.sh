#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPER="$ROOT_DIR/scripts/keeper"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-cli-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# A real vault has .obsidian at its root; vault_index_apply finds it to write
# vault-root-relative link targets. Without it the fixture exercises a shape
# production never sees.
V="$TMP/vault"; mkdir -p "$V/.obsidian"
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

# --- insert subcommand ---
printf '%s\n' '---' 'date: 2026-06-29' '---' '' '# My Session Note' 'content' > "$TMP/note.md"

# I1: insert writes the note verbatim; vault_index_apply owns the INDEX link.
# One note gets exactly ONE link, and it resolves — keeper must not hand-append
# a `- [[$title]]` of its own. When --title differed from the filename stem that
# produced two entries, the title one dangling, and the count-based coverage
# check read the result as healthy.
NF="$V/Decisions/2026-06-29-my-note.md"
bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-06-29-my-note.md" \
  --body-file "$TMP/note.md" --title "My Session Note" >/dev/null
[ -f "$NF" ]                          || fail "insert did not write the note"
grep -q '^# My Session Note' "$NF"    || fail "insert body not written verbatim"
[ -f "$V/Decisions/INDEX.md" ]        || fail "insert did not create folder INDEX"
[ "$(grep -cF -- '- [[' "$V/Decisions/INDEX.md")" = "1" ] \
  || fail "expected exactly one INDEX link, got:"$'\n'"$(cat "$V/Decisions/INDEX.md")"
grep -qxF -- '- [[Decisions/2026-06-29-my-note]]' "$V/Decisions/INDEX.md" \
  || fail "INDEX link is not the resolvable path form:"$'\n'"$(cat "$V/Decisions/INDEX.md")"
grep -qF -- '[[My Session Note]]' "$V/Decisions/INDEX.md" \
  && fail "keeper hand-appended a title link; apply owns the link write"

# I2: refuse-on-exists (never overwrite)
bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-06-29-my-note.md" --body-file "$TMP/note.md" 2>/dev/null && fail "insert must refuse to overwrite an existing note"

# I3: --session-link-date links into Daily/<date> under ## Session Links.
# The link target is the note's vault-relative path so it resolves from Daily/;
# the human title rides along as an alias. A bare `- [[Other Note]]` pointed at
# no file at all.
DLY="$V/Daily/2026-06-29.md"
bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-06-29-other.md" \
  --body-file "$TMP/note.md" --title "Other Note" --session-link-date 2026-06-29 >/dev/null
[ -f "$DLY" ]                          || fail "session-link-date did not create the daily note"
grep -q '^## Session Links' "$DLY"     || fail "Session Links section missing"
grep -qxF -- '- [[Decisions/2026-06-29-other|Other Note]]' "$DLY" \
  || fail "Session Links entry is not the resolvable path|alias form:"$'\n'"$(cat "$DLY")"

# I4: two distinct notes sharing a title each get their own Session Links entry —
# they are different files. Deduping on title text dropped the second note's
# link entirely, silently losing it from the day's log.
bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-06-29-dup.md" \
  --body-file "$TMP/note.md" --title "Other Note" --session-link-date 2026-06-29 >/dev/null
grep -qxF -- '- [[Decisions/2026-06-29-dup|Other Note]]' "$DLY" \
  || fail "second same-titled note lost its Session Links entry:"$'\n'"$(cat "$DLY")"

# I4b: re-linking the SAME note is still idempotent (dedup is per path, not per title).
bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-06-29-again.md" \
  --body-file "$TMP/note.md" --title "Again" --session-link-date 2026-06-29 >/dev/null
bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-06-29-again.md" \
  --body-file "$TMP/note.md" --title "Again" --session-link-date 2026-06-29 2>/dev/null \
  && fail "insert must refuse to overwrite; I4b cannot test dedup this way"
[ "$(grep -cF -- '[[Decisions/2026-06-29-again' "$DLY")" = "1" ] \
  || fail "Session Links entry duplicated for one note"

# I5: malformed --session-link-date rejected
bash "$KEEPER" insert --vault "$V" --target "Decisions/z.md" --body-file "$TMP/note.md" --session-link-date "2026/06/29" 2>/dev/null && fail "malformed session-link-date must fail"

# I6: --title default is the filename stem (date prefix KEPT, so the wikilink resolves)
bash "$KEEPER" insert --vault "$V" --target "Notes/2026-06-29-derived-title.md" --body-file "$TMP/note.md" >/dev/null
grep -qxF -- '- [[Notes/2026-06-29-derived-title]]' "$V/Notes/INDEX.md" || fail "default title (filename stem) failed"

# I7: --title default without a date prefix keeps the full basename
bash "$KEEPER" insert --vault "$V" --target "Notes/plain.md" --body-file "$TMP/note.md" >/dev/null
grep -qxF -- '- [[Notes/plain]]' "$V/Notes/INDEX.md" || fail "default title (no date prefix) failed"

# I8: insert path-traversal guard
bash "$KEEPER" insert --vault "$V" --target "../evil.md" --body-file "$TMP/note.md" 2>/dev/null && fail "insert path traversal must fail"
[ -f "$TMP/evil.md" ] && fail "insert traversal wrote outside the vault"

# 14. zsh portability — both subcommands clean under zsh (insert sources the substrate libs)
if command -v zsh >/dev/null 2>&1; then
  zsh "$KEEPER" append --vault "$V" --target "Notes/z.md" --section '## z — t' --body-file "$TMP/b.md" >/dev/null 2>"$TMP/zerr" \
    || { cat "$TMP/zerr" >&2; fail "keeper append broke under zsh"; }
  grep -q '^## z — t' "$V/Notes/z.md" || fail "zsh keeper append did not write"
  zsh "$KEEPER" insert --vault "$V" --target "Notes/2026-06-29-zinsert.md" \
    --body-file "$TMP/note.md" --title "Z Insert" --session-link-date 2026-06-29 >/dev/null 2>>"$TMP/zerr" \
    || { cat "$TMP/zerr" >&2; fail "keeper insert broke under zsh"; }
  grep -qxF -- '- [[Notes/2026-06-29-zinsert]]' "$V/Notes/INDEX.md" || fail "zsh keeper insert did not link INDEX"
fi

echo "PASS: keeper-cli"
