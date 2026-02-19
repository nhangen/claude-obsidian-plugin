---
name: obsidian-find-notes
description: Searches the Obsidian vault and returns matching notes. Triggers on phrases like "find my notes on X", "what did I write about Y", "search obsidian for Z", "do I have any notes about", "find in vault", "look up in obsidian".
version: 1.0.0
---

# Find Notes in Obsidian

Searches the vault for notes matching a query.

## Vault Path

`/mnt/z/Users/nhang/Documents/Obsidian` (alias: `~/obsidian`)

## Search Strategy

1. **Filename search** — `find ~/obsidian -name "*<query>*" -type f`
2. **Content search** — `grep -r -l -i "<query>" ~/obsidian --include="*.md" --exclude-dir=".obsidian"`
3. **Frontmatter/tag search** — `grep -r -l "tags:.*<query>" ~/obsidian --include="*.md"`

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

1. Parse query from user request
2. Run all three searches against vault
3. Deduplicate and rank results
4. Display top 5 results with previews
5. Offer to open any result: "Open note 2 in Obsidian?"
6. If user selects one, call `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <path>`
