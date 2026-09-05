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

# 6b. a bare --section title is written as a heading, not a paragraph. Plain
#     text is invisible to Obsidian's outline, and — because the --skip-if-hash
#     gate reads headings — a section written flat cannot be found by the sha
#     dedup either, so the same commit captures twice (#100).
printf 'flat body\n' > "$TMP/flat.md"
bash "$KEEPER" append --vault "$V" --target "Notes/flat.md" \
  --section 'Some title 1234abc' --body-file "$TMP/flat.md" >/dev/null
grep -qxF -- '## Some title 1234abc' "$V/Notes/flat.md" \
  || fail "a bare --section title was not promoted to a heading:"$'\n'"$(cat "$V/Notes/flat.md")"
FLAT_BEFORE="$(cat "$V/Notes/flat.md")"
bash "$KEEPER" append --vault "$V" --target "Notes/flat.md" \
  --section 'Some title 1234abc' --body-file "$TMP/flat.md" --skip-if-hash 1234abc >/dev/null 2>&1
[ "$(cat "$V/Notes/flat.md")" = "$FLAT_BEFORE" ] \
  || fail "a section written from a bare title was not seen by the sha gate"

# 6c. a --section that already carries its own hashes keeps the level it chose;
#     keeper must not double-prefix it.
bash "$KEEPER" append --vault "$V" --target "Notes/level.md" \
  --section '#### deep section' --body-file "$TMP/b.md" >/dev/null
grep -qxF -- '#### deep section' "$V/Notes/level.md" \
  || fail "an explicit heading level was rewritten:"$'\n'"$(cat "$V/Notes/level.md")"

# 6d. a whitespace-only --section falls back to the default heading rather than
#     emitting an empty one.
bash "$KEEPER" append --vault "$V" --target "Notes/blank.md" --section '   ' \
  --body-file "$TMP/b.md" >/dev/null
grep -qE '^## [0-9]{2}:[0-9]{2} — entry' "$V/Notes/blank.md" \
  || fail "a blank --section did not fall back to the default heading:"$'\n'"$(cat "$V/Notes/blank.md")"

# --- --skip-if-hash: the append is idempotent per commit sha ---
#
# The capture gate this replaces lived in a host-local state dir while the vault
# is Syncthing-replicated (#62), so it could not see the note it was protecting.
# The note itself is the shared record, and it is what the guard reads.

# 15. a second append for a sha the target already has a section for is a no-op:
#     no new section, no duplicated body, and the reason goes to stderr.
S="$V/Projects/foo/2026-06-29.md"
BEFORE="$(cat "$S")"
printf 'a second capture of the same commit\n' > "$TMP/dup.md"
bash "$KEEPER" append --vault "$V" --target "Projects/foo/2026-06-29.md" \
  --section '## 16:45 — abc1234' --body-file "$TMP/dup.md" --skip-if-hash abc1234 \
  >"$TMP/skip.out" 2>"$TMP/skip.err" \
  || fail "--skip-if-hash on an already-captured sha must exit 0, not fail"
[ "$(cat "$S")" = "$BEFORE" ] \
  || fail "--skip-if-hash appended anyway; the target changed:"$'\n'"$(diff <(printf '%s\n' "$BEFORE") "$S" || true)"
grep -q 'skipped' "$TMP/skip.err" \
  || fail "the skip was silent — nothing on stderr said why nothing was written:"$'\n'"$(cat "$TMP/skip.err")"
grep -qF "Projects/foo/2026-06-29.md" "$TMP/skip.out" \
  || fail "skip did not print the target path on stdout, so a caller cannot tell which note holds it"

# 16. a sha the target does NOT have appends normally — the guard is per sha, not
#     a blanket "this file already exists" refusal.
bash "$KEEPER" append --vault "$V" --target "Projects/foo/2026-06-29.md" \
  --section '## 17:00 — 99f00d5' --body-file "$TMP/dup.md" --skip-if-hash 99f00d5 >/dev/null
grep -q '^## 17:00 — 99f00d5' "$S" || fail "--skip-if-hash blocked an sha the note did not have"

# 17. the guard reads section headings, not prose. A context bullet is free to
#     mention another commit's sha; matching anywhere in the file would then
#     silently drop that commit's own record.
printf 'reverts deadbee, see also deadbee\n' > "$TMP/prose.md"
bash "$KEEPER" append --vault "$V" --target "Notes/prose.md" \
  --section '## 12:00 — 1111111' --body-file "$TMP/prose.md" >/dev/null
bash "$KEEPER" append --vault "$V" --target "Notes/prose.md" \
  --section '## 12:05 — deadbee' --body-file "$TMP/b.md" --skip-if-hash deadbee >/dev/null
grep -q '^## 12:05 — deadbee' "$V/Notes/prose.md" \
  || fail "a sha mentioned in body prose was read as an existing section, dropping the record"

# 17b. the sha may sit anywhere in the heading. Commit capture writes it at the
#      START ("## <sha> — msg"), and an end-anchored match never fired for that
#      shape, so the only guard against a double capture was dead (#101).
printf 'first capture\n' > "$TMP/lead.md"
bash "$KEEPER" append --vault "$V" --target "Notes/lead.md" \
  --section '## 7ac9556 — repair the two guards (PR #357)' --body-file "$TMP/lead.md" >/dev/null
LEAD_BEFORE="$(cat "$V/Notes/lead.md")"
bash "$KEEPER" append --vault "$V" --target "Notes/lead.md" \
  --section '## 7ac9556 — repair the two guards (PR #357)' --body-file "$TMP/dup.md" \
  --skip-if-hash 7ac9556 >/dev/null 2>&1
[ "$(cat "$V/Notes/lead.md")" = "$LEAD_BEFORE" ] \
  || fail "a sha at the start of the heading was not seen, so the commit was captured twice"

# 17c. the sha is compared case-insensitively — the validator accepts [0-9a-fA-F],
#      so a caller passing an uppercase sha must still hit its own section.
bash "$KEEPER" append --vault "$V" --target "Notes/lead.md" \
  --section '## 7AC9556 — same commit, uppercase' --body-file "$TMP/dup.md" \
  --skip-if-hash 7AC9556 >/dev/null 2>&1
[ "$(cat "$V/Notes/lead.md")" = "$LEAD_BEFORE" ] \
  || fail "an uppercase --skip-if-hash missed the lowercase section it names"

# 17d. the boundary is real: a heading naming a LONGER sha that merely starts
#      with this one is a different commit and must not suppress it.
printf 'longer sha section\n' > "$TMP/long.md"
bash "$KEEPER" append --vault "$V" --target "Notes/boundary.md" \
  --section '## abc12345 — a different commit' --body-file "$TMP/long.md" >/dev/null
bash "$KEEPER" append --vault "$V" --target "Notes/boundary.md" \
  --section '## abc1234 — the commit we mean' --body-file "$TMP/b.md" --skip-if-hash abc1234 >/dev/null
grep -q '^## abc1234 — the commit we mean' "$V/Notes/boundary.md" \
  || fail "a heading for a longer sha with the same prefix suppressed a distinct commit"

# 18. a malformed --skip-if-hash fails loudly. Silently treating an unusable
#     value as "no guard" turns a typo into a duplicate note, which is the
#     failure this flag exists to prevent.
bash "$KEEPER" append --vault "$V" --target "Notes/bad.md" --section x \
  --body-file "$TMP/b.md" --skip-if-hash "not-a-sha" 2>/dev/null \
  && fail "non-hex --skip-if-hash must fail rather than append unguarded"
[ -f "$V/Notes/bad.md" ] && fail "a rejected --skip-if-hash still wrote the note"
bash "$KEEPER" append --vault "$V" --target "Notes/bad.md" --section x \
  --body-file "$TMP/b.md" --skip-if-hash "" 2>/dev/null \
  && fail "empty --skip-if-hash must fail rather than append unguarded"

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

# I4b: the Session Links dedup is per path. A second insert of the same note
#      cannot test it — the overwrite guard rejects that before the link step
#      ever runs, so the assertion passed on the early abort rather than on the
#      dedup. Seed the link into the daily note instead, which is the state a
#      Syncthing round-trip or a hand-edit leaves, and let the insert reach the
#      branch.
awk '{print} /^## Session Links/ && !d {print "- [[Decisions/2026-06-29-seeded|Seeded]]"; d=1}' \
  "$DLY" > "$DLY.seed" && mv "$DLY.seed" "$DLY"
[ "$(grep -cF -- '[[Decisions/2026-06-29-seeded' "$DLY")" = "1" ] \
  || fail "fixture precondition: the seeded link should appear exactly once"
bash "$KEEPER" insert --vault "$V" --target "Decisions/2026-06-29-seeded.md" \
  --body-file "$TMP/note.md" --title "Seeded" --session-link-date 2026-06-29 >/dev/null
[ "$(grep -cF -- '[[Decisions/2026-06-29-seeded' "$DLY")" = "1" ] \
  || fail "Session Links entry duplicated for a note the daily note already linked:"$'\n'"$(grep -F 'seeded' "$DLY")"

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

# I9: a healthy insert raises no link warning — the warning below must mean
#     something when it appears.
bash "$KEEPER" insert --vault "$V" --target "Notes/quiet.md" \
  --body-file "$TMP/note.md" >/dev/null 2>"$TMP/quiet.err"
grep -q 'keeper: warning' "$TMP/quiet.err" \
  && fail "insert warned about a link it did write:"$'\n'"$(cat "$TMP/quiet.err")"

# I10: when the INDEX link cannot be written, insert says so. The note is
#      committed before the link step, so swallowing the failure with `|| true`
#      let the CLI print the path and exit 0 on a note nothing links to (#104).
if [ "$(id -u)" = "0" ]; then
  printf 'skip: unlinkable-INDEX assertion (running as root ignores 0444)\n' >&2
else
  mkdir -p "$V/Locked"
  printf '# Locked Index\n' > "$V/Locked/INDEX.md"
  chmod 444 "$V/Locked/INDEX.md"
  set +e
  bash "$KEEPER" insert --vault "$V" --target "Locked/2026-06-29-orphan.md" \
    --body-file "$TMP/note.md" >"$TMP/lock.out" 2>"$TMP/lock.err"
  LOCK_RC=$?
  set -e
  chmod 644 "$V/Locked/INDEX.md"
  [ "$LOCK_RC" = "0" ] \
    || fail "the note itself committed, so insert must still exit 0; rc=$LOCK_RC"
  [ -f "$V/Locked/2026-06-29-orphan.md" ] || fail "insert did not write the note"
  grep -q 'not linked from' "$TMP/lock.err" \
    || fail "insert reported success on an unlinked note; stderr was:"$'\n'"$(cat "$TMP/lock.err")"
fi

# I11: a Daily/ note that cannot be replaced leaves no stray temp file behind,
#      and says so. `> "$daily.ktmp" && mv` left a .ktmp in the user's Daily/
#      folder on failure — and since the note itself commits first, the obvious
#      retry then died on "target already exists" rather than re-linking.
if [ "$(id -u)" = "0" ]; then
  printf 'skip: unwritable-daily assertion (running as root ignores 0444)\n' >&2
else
  # The directory, not the file: rename(2) needs write permission on the
  # directory, so a 0444 daily note is still replaceable and nothing fails.
  LOCKDAY="$V/Daily/2026-07-01.md"
  printf -- '---\ndate: 2026-07-01\n---\n\n## Session Links\n' > "$LOCKDAY"
  chmod 555 "$V/Daily"
  set +e
  bash "$KEEPER" insert --vault "$V" --target "Notes/2026-07-01-locked-daily.md" \
    --body-file "$TMP/note.md" --title "Locked Daily" --session-link-date 2026-07-01 \
    >"$TMP/lockday.out" 2>"$TMP/lockday.err"
  LOCKDAY_RC=$?
  set -e
  chmod 755 "$V/Daily"
  [ "$LOCKDAY_RC" = "0" ] \
    || fail "the note committed, so insert must still exit 0; rc=$LOCKDAY_RC"
  [ -f "$V/Notes/2026-07-01-locked-daily.md" ] || fail "insert did not write the note"
  grep -qE 'could not be linked into Daily|Daily/ is unwritable' "$TMP/lockday.err" \
    || fail "an unlinkable daily note was silent:"$'\n'"$(cat "$TMP/lockday.err")"
  STRAY="$(find "$V/Daily" -maxdepth 1 -name '*ktmp*' | wc -l | tr -d ' ')"
  [ "$STRAY" = "0" ] \
    || fail "$STRAY stray temp file(s) left in Daily/ after a failed session link"

  # I11b: the same, for the day that has NO daily note yet — the shape the
  # fixture above skips, and the one where the unguarded writes lived. Creating
  # the note, appending the section and swapping are three separate writes;
  # guarding only the last still aborts the insert after the note committed,
  # which a caller reads as "not captured" for a capture that happened.
  chmod 555 "$V/Daily"
  set +e
  bash "$KEEPER" insert --vault "$V" --target "Notes/2026-07-02-no-daily-yet.md" \
    --body-file "$TMP/note.md" --title "No Daily Yet" --session-link-date 2026-07-02 \
    >"$TMP/nodaily.out" 2>"$TMP/nodaily.err"
  NODAILY_RC=$?
  set -e
  chmod 755 "$V/Daily"
  [ "$NODAILY_RC" = "0" ] \
    || fail "insert exited $NODAILY_RC after committing the note; a caller reads that as 'not captured'"
  [ -f "$V/Notes/2026-07-02-no-daily-yet.md" ] || fail "insert did not write the note"
  # The vault-relative suffix, not "$V/...": $TMPDIR is a symlink on macOS
  # (/var -> /private/var) and keeper resolves it, so the absolute forms never
  # match there and this arm failed on every run.
  grep -qF "Notes/2026-07-02-no-daily-yet.md" "$TMP/nodaily.out" \
    || fail "insert printed no path for a note it committed:"$'\n'"$(cat "$TMP/nodaily.out")"
  grep -q 'no session link' "$TMP/nodaily.err" \
    || fail "an uncreatable daily note was silent:"$'\n'"$(cat "$TMP/nodaily.err")"
fi

# I10b: the INDEX creation write is the third bare write after the note
# commits. `[ -f "$idx" ] || printf ... > "$idx"` aborts under `set -e` when
# INDEX.md cannot be created -- an INDEX.md that is a directory is the cheap
# reproduction, ENOSPC the real one -- so insert exits 1 having written the
# note, which callers read as "not captured". Same invariant as I10 and I11b.
if [ "$(id -u)" = "0" ]; then
  printf 'skip: unwritable-INDEX assertion (running as root)\n' >&2
else
  mkdir -p "$V/Blocked"
  mkdir -p "$V/Blocked/INDEX.md"
  set +e
  bash "$KEEPER" insert --vault "$V" --target "Blocked/2026-07-03-blocked-index.md" \
    --body-file "$TMP/note.md" --title "Blocked Index" \
    >"$TMP/blockidx.out" 2>"$TMP/blockidx.err"
  BLOCKIDX_RC=$?
  set -e
  [ "$BLOCKIDX_RC" = "0" ] \
    || fail "the note committed, so insert must still exit 0 with an unusable INDEX; rc=$BLOCKIDX_RC"$'\n'"$(cat "$TMP/blockidx.err")"
  [ -f "$V/Blocked/2026-07-03-blocked-index.md" ] || fail "insert did not write the note"
  grep -q 'keeper: warning' "$TMP/blockidx.err" \
    || fail "an unusable INDEX.md was silent:"$'\n'"$(cat "$TMP/blockidx.err")"
  rmdir "$V/Blocked/INDEX.md" 2>/dev/null || true
fi

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
