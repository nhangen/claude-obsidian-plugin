---
name: commit-capture
description: Captures conversation context around git commits to Obsidian vault. Fires automatically via PostToolUse hook.
version: 2.4.0
---

# Commit Capture

The value here is not commit metadata — git already has that. The value is the conversation context: what you were investigating, what you tried, what you decided, and why.

## Architecture

Detection and metadata extraction are handled by two shell hooks (zero AI cost): `scripts/commit-capture-pre.sh` records `HEAD` before a `git commit` runs, and `scripts/commit-capture.sh` captures only if `HEAD` moved. This skill is invoked when the post-hook outputs a line starting with `obsidian-commit-capture:` — all metadata is inline, no file read needed.

**Only a line beginning `obsidian-commit-capture: hash=` is a record.** Records and diagnostics arrive the same way, wrapped in a system reminder next to the tool result: a PostToolUse hook that exits 0 reaches Claude only through `hookSpecificOutput.additionalContext`, so that is where both go. Two other prefixes exist:

- `obsidian-commit-capture: not captured — …` — nothing was captured, and the rest of the line says why. Do not write a note. Surface the reason if the user asks why a commit went uncaptured, or if it names a fix (an unregistered hook, an unwritable state dir, a missing `vault_path`).
- `obsidian-commit-capture: partial — …` — a record follows, but the call made more commits than the one captured, and the line lists the shas that were skipped. Write the note for the record; mention the skipped shas only if the user is reconciling history.

The actual write goes through the **keeper CLI** (`scripts/keeper append`) — the
keeper's deterministic write primitive. The CLI creates the file on absence,
makes parent dirs, and appends the section; this skill does not `Read`/`Write`/
`mkdir` directly. The CLI is a plain command (zero AI cost, **no subagent**), so
commit-capture stays as cheap as before — the keeper is used, via command. This
skill's only job is to synthesize the context bullets (which require the
conversation, so they must be built here in the agent turn) and hand the write
to the CLI.

## Config

Vault path is passed inline by the hook (parsed once from the resolved config — `$OBSIDIAN_LOCAL_MD`, else `${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`, else the plugin dir). Do **not** Read the config file from this skill — every read costs ~1-2K tokens per commit. If `vault_path` is empty in the hook output, skip silently (the config is missing or malformed).

## Steps

1. **Parse inline metadata** from the hook output line:
   `obsidian-commit-capture: hash=<h> | branch=<b> | files=<f> | org_repo=<o> | repo_name=<r> | ticket=<t> | date=<d> | time=<ti> | vault_path=<v> | msg=<m>`
   Extract: `hash`, `branch`, `files`, `org_repo`, `repo_name`, `ticket`, `date`, `time`, `vault_path`, `msg`.

   `msg` is last and everything after `msg=` belongs to it. It is the one
   free-form field — a commit author writes it — so it cannot precede a field you
   resolve into a path. Take the **first** match for every other field, and never
   re-read a field name out of `msg`.

2. **Target** (relative to `vault_path`): `Projects/Development/<org_repo>/<date>.md`.

3. **Build the session context** — this is the primary output and the only part
   that needs the conversation (so it must be done here, in the agent turn).

   Review the full conversation since the last commit (or session start if first commit). Capture:

   - **Goal** — what task or problem was being worked on
   - **Investigation** — what was explored, what files were read, what was searched for
   - **Decisions** — choices made, alternatives considered and rejected, tradeoffs
   - **Debugging** — if applicable: symptoms, hypotheses tested, root cause found
   - **Loose ends** — anything unresolved, flagged for follow-up, or noted for later

   3-8 bullet points. Dense and specific. Written so you can reconstruct the reasoning months later.

4. **Write the body** to a temp file — the section content the keeper will append:

   ```markdown
   **Branch:** <branch>
   **Message:** <msg>
   **Files:** <files>

   ### Context

   - <bullet points from step 3>

   ---
   ```

5. **Write the new-file header** to a second temp file — used by the keeper only
   if the dated note doesn't exist yet:

   ```markdown
   ---
   date: <date>
   repo: <org_repo>
   tags: [<repo_name>, auto-captured]
   source: claude-code
   ---

   # <repo_name> — <date>
   ```

   If `ticket` is non-empty, add `ticket-<ticket>` to the tags array.

6. **Hand the write to the keeper CLI:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/keeper" append \
     --vault "<vault_path>" \
     --target "Projects/Development/<org_repo>/<date>.md" \
     --section "## <time> — <hash>" \
     --body-file "<body-temp>" \
     --init-file "<header-temp>"
   ```

   The CLI creates parent dirs, writes the header on first commit of the day,
   and appends the section. No `Read`/`Write`/`mkdir`, no subagent.

7. **Confirm silently** — output only: `Captured <hash> → <org_repo>/<date>.md`

## Important

- Do NOT open the note in Obsidian GUI
- Do NOT modify the daily note
- The context section is the whole point — never skip it
- If the hook output line is missing or malformed, skip silently
