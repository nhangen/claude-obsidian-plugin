# Obsidian Commit Capture

After every successful `git commit`, capture the conversation context to an Obsidian vault note. This preserves the reasoning, investigation, and decisions that led to the commit — context that git alone does not store.

## When to trigger

Only after a git commit succeeds. Do not trigger on failed commits, dry runs, or non-commit git commands.

## How to capture

1. Extract metadata:
   ```bash
   HASH=$(git rev-parse --short HEAD)
   MSG=$(git log -1 --pretty=format:'%s')
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   FILES=$(git diff --name-only HEAD~1..HEAD | tr '\n' ',' | sed 's/,$//')
   REMOTE=$(git remote get-url origin 2>/dev/null || echo "local")
   ```

2. Derive `org/repo` from remote:
   - SSH `git@host:org/repo.git` → `org/repo`
   - HTTPS `https://github.com/org/repo.git` → `org/repo`
   - No remote → `local/<dir-name>`

3. Find the vault config: check `~/.claude/plugins/marketplaces/nhangen/obsidian.local.md` first, then fall back to `~/Documents/Obsidian` if not found. Read the `vault_path` frontmatter field.

4. Target file: `<vault_path>/Projects/Development/<org_repo>/<YYYY-MM-DD>.md`

5. Write a context section (3-8 bullet points) capturing:
   - **Goal** — what task or problem was being worked on
   - **Investigation** — what was explored, searched, read
   - **Decisions** — choices made, alternatives rejected
   - **Debugging** — if applicable: symptoms, hypotheses, root cause
   - **Loose ends** — anything unresolved or flagged for later

6. If the file is new, create it with frontmatter:
   ```markdown
   ---
   date: YYYY-MM-DD
   repo: <org_repo>
   tags: [<repo_name>, auto-captured]
   source: codex
   ---

   # <repo_name> — YYYY-MM-DD
   ```

7. Append a section:
   ```markdown

   ## HH:MM — <hash>

   **Branch:** <branch>
   **Message:** <msg>
   **Files:** <files>

   ### Context

   - <bullet points>

   ---
   ```

8. Create parent directories if needed (`mkdir -p`).

9. Confirm: `Captured <hash> → <org_repo>/<date>.md`
