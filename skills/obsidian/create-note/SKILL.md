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
5. **Create dirs if needed** — `mkdir -p <path>`
6. **Write file(s)** — use Write tool
7. **Confirm path** — tell user exactly where it was created
8. **Open in GUI** — `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <path>`

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
