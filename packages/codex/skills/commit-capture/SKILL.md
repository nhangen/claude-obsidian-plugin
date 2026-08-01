---
name: commit-capture
description: Capture Codex conversation context in Obsidian immediately after every successful git commit. Use this installed skill after a commit succeeds; never use it for failed commits, dry runs, or non-commit Git commands. It obtains safe metadata through its bundled commit-meta.sh and writes through its bundled keeper.
---

# Obsidian Commit Capture

Preserve why a commit happened. Git already stores the code and subject; the note stores the goal, investigation, decisions, debugging, and loose ends from the conversation.

Codex does not currently deliver this plugin's bundled tool hooks in a normal CLI session. Invoke this skill after the successful commit instead of waiting for a hook record.

## Capture workflow

1. Resolve bundled files relative to this `SKILL.md`. Do not search Claude or Codex plugin caches and do not reconstruct metadata with Git commands.
2. Run the bundled helper for the repository where the commit landed:

   ```bash
   bash "<this skill directory>/scripts/commit-meta.sh" -C "<repository>"
   ```

   A non-zero exit means there is no capture. Report its stderr and stop. Never guess missing values.

3. Parse the one-line record:

   ```text
   hash=<h> | branch=<b> | files=<f> | org_repo=<o> | repo_name=<r> | ticket=<t> | date=<d> | time=<ti> | vault_path=<v> | msg=<m>
   ```

   Take the first match for every field except `msg`. The message is last and consumes the remainder. Never parse a field name from the message.

4. Choose exactly one target relative to `vault_path`:
   - `awesomemotive/*` -> `Awesome Motive/sessions/<date>-<repo_name>.md`
   - `altamira2/mtf-builder` -> `Altamira/mtf-builder/commits/<date>-mtf-builder-commits.md`
   - otherwise -> `Projects/Development/<org_repo>/<date>.md`
5. Write 3-8 dense context bullets covering the goal, investigation, decisions, debugging when relevant, and loose ends. Use conversation context since the preceding commit, or since session start for the first commit.
6. Put this section body in a temporary file:

   ```markdown
   **Branch:** <branch>
   **Message:** <msg>
   **Files:** <files>

   ### Context

   - <context bullets>

   ---
   ```

7. Put this new-file header in a second temporary file. Add `ticket-<ticket>` to the tags when the ticket is non-empty:

   ```markdown
   ---
   date: <date>
   repo: <org_repo>
   tags: [<repo_name>, auto-captured]
   source: codex
   ---

   # <repo_name> - <date>
   ```

8. Append through the bundled keeper:

   ```bash
   bash "<this skill directory>/scripts/keeper" append \
     --vault "<vault_path>" \
     --target "<chosen target>" \
     --section "## <time> - <hash>" \
     --body-file "<body temp>" \
     --init-file "<header temp>" \
     --skip-if-hash "<hash>"
   ```

9. Report `Captured <hash> -> <target>` only after a zero exit. If stderr says `append skipped`, report `Already captured <hash> -> <target>`. On any non-zero exit, report that the commit was not captured and include the error.

Do not open Obsidian, modify the daily note, write one commit to multiple targets, omit the context bullets, or omit `--skip-if-hash`.
