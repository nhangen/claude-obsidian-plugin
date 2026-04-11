---
name: obsidian-find-notes
description: Searches the Obsidian vault and returns matching notes. Triggers on phrases like "find my notes on X", "what did I write about Y", "search obsidian for Z", "do I have any notes about", "find in vault", "look up in obsidian".
version: 1.0.0
---

# Find Notes in Obsidian

Searches the vault for notes matching a query.

## Vault Path

Read `vault_path` from `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`.

If `obsidian.local.md` does not exist, tell the user to run `/obsidian:setup` first and stop.

## Search Strategy

1. **Filename search** — `find "$VAULT_PATH" -name "*<query>*" -type f`
2. **Content search** — `grep -r -l -i "<query>" "$VAULT_PATH" --include="*.md" --exclude-dir=".obsidian"`
3. **Frontmatter/tag search** — `grep -r -l "tags:.*<query>" "$VAULT_PATH" --include="*.md"`

Combine and deduplicate results. Rank by:
- Exact title match (highest)
- Recent modification date
- Number of keyword occurrences in content

## Output Format

For each match, show:
```
**[[Note Title]]**
Path: Projects/Domain/Note-Title.md
Last modified: YYYY-MM-DD
Preview: ...first 2-3 relevant lines...
```

## Steps

1. If `VAULT.md` exists at the vault root, read it for vault-specific structure conventions (e.g., index files, special folders to prioritize in search)
2. Parse query from user request
3. Run all three searches against vault
4. Deduplicate and rank results
5. Display top 5 results with previews
6. Offer to open any result: "Open note 2 in Obsidian?"
7. If user selects one, call `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <path>`
