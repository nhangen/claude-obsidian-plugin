---
name: obsidian-commit-capture
description: Captures conversation context around git commits to Obsidian vault. Fires automatically via PostToolUse hook.
version: 2.1.0
---

# Commit Capture

The value here is not commit metadata — git already has that. The value is the conversation context: what you were investigating, what you tried, what you decided, and why.

## Architecture

Detection and metadata extraction are handled by `scripts/commit-capture.sh` (shell script, zero AI cost). This skill is invoked when the hook outputs a line starting with `obsidian-commit-capture:` — all metadata is inline, no file read needed.

## Config

Read vault path from: `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`

## Steps

1. **Parse inline metadata** from the hook output line:
   `obsidian-commit-capture: hash=<h> | msg=<m> | branch=<b> | files=<f> | org_repo=<o> | repo_name=<r> | ticket=<t> | date=<d> | time=<ti>`
   Extract: `hash`, `msg`, `branch`, `files`, `org_repo`, `repo_name`, `ticket`, `date`, `time`.

2. **Determine target path** (relative to vault_path from config):
   `Projects/Development/<org_repo>/<date>.md`

3. **Read existing file** at the target path. If it doesn't exist, create it.

4. **If file is new**, write with this template:

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

5. **Build the session context** — this is the primary output.

   Review the full conversation since the last commit (or session start if first commit). Capture:

   - **Goal** — what task or problem was being worked on
   - **Investigation** — what was explored, what files were read, what was searched for
   - **Decisions** — choices made, alternatives considered and rejected, tradeoffs
   - **Debugging** — if applicable: symptoms, hypotheses tested, root cause found
   - **Loose ends** — anything unresolved, flagged for follow-up, or noted for later

   3-8 bullet points. Dense and specific. Written so you can reconstruct the reasoning months later.

6. **Append this section** to the end of the file:

   ```markdown

   ## <time> — <hash>

   **Branch:** <branch>
   **Message:** <msg>
   **Files:** <files>

   ### Context

   - <bullet points from step 5>

   ---
   ```

7. **Create parent directories** if needed (`mkdir -p` via Bash).

8. **No file cleanup needed** — metadata was passed inline, no temp file was written.

9. **Confirm silently** — output only: `Captured <hash> → <org_repo>/<date>.md`

## Important

- Do NOT open the note in Obsidian GUI
- Do NOT modify the daily note
- The context section is the whole point — never skip it
- If the hook output line is missing or malformed, skip silently
