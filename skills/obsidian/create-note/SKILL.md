---
name: obsidian-create-note
description: Creates a new note, project folder, or page in the Obsidian vault. Triggers on phrases like "create a note about X", "start a new project for Y", "add a page for Z", "new obsidian note", "create project folder", "set up a new project in obsidian".
version: 1.0.0
---

# Create Note in Obsidian

Creates new notes or project structures in the vault.

## Vault Path

Read `vault_path` from `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`. Example:
```bash
VAULT_PATH=$(grep '^vault_path:' "${CLAUDE_PLUGIN_ROOT}/obsidian.local.md" | sed 's/vault_path: //')
```

If `obsidian.local.md` does not exist, tell the user to run `/obsidian:setup` first and stop.

## Steps

1. **Check for vault conventions** — if `VAULT.md` exists at the vault root, read it. Follow any structure conventions it defines (e.g., custom note types, templates folder, naming conventions). If no `VAULT.md` exists, use the defaults below.
2. **Determine type** — single note, project folder (with README + subfolders), or page in existing project
3. **Route to correct domain** — use routing logic from `obsidian-save-conversation` skill
4. **Generate content** — create appropriate starter template:
   - Single note: title + frontmatter + H1 + empty sections
   - Project: `README.md` + subfolders (Plans, Notes, Meetings as appropriate)
5. **Validate allow-list** — `strict_domains` defaults to `true` when absent from the config frontmatter; only an explicit `false` skips validation. When on:
   - Parse the `## Project Taxonomy` table from `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`; the `Vault path` column is the canonical allow-list of top-level folders.
   - Normalize both the allow-list entries and the resolved target before comparison: strip any trailing `/`, and lowercase both sides (macOS HFS+/default APFS is case-insensitive).
   - Compute the resolved target's top-level prefix (path up to and including the first allow-listed root match). Dated subfolders and per-repo namespacing *under* an allow-listed root are valid.
   - If no normalized allow-list entry is a prefix of the normalized target, **refuse to write**. Surface the closest match (Levenshtein on the top-level component, original casing from the taxonomy) and tell the user:
     > Refusing to write to `<target>` — top-level folder is not in the allow-list. Closest match: `<closest>`. Either correct the topic hint, or add `<target-toplevel>` to `## Project Taxonomy` in `obsidian.local.md` (or rerun `/obsidian:setup`).
   - Do not create unrecognized top-level folders. Topic hints that fuzzy-match must themselves resolve to an existing taxonomy row.
6. **Create dirs if needed** — `mkdir -p <path>` (only after validation passes)
7. **Write file(s)** — use Write tool
8. **Confirm path** — tell user exactly where it was created
9. **Open in GUI** — `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <path>`

## Note Template

```markdown
---
date: YYYY-MM-DD
tags: []
---

# Title

## Overview

## Notes

## Related

- [[]]
```

## Project README Template

```markdown
---
date: YYYY-MM-DD
type: project
status: active
---

# Project Name

## Goal

## Key Files

## Status
```
