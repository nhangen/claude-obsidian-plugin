---
name: obsidian-reorganize
description: Reorganizes the Obsidian vault or a specific project. Triggers on phrases like "reorganize my vault", "clean up obsidian", "move X to Y in obsidian", "reorganize my notes", "restructure my projects", "organize the vault". Launches the vault-organizer subagent for deep analysis and execution.
version: 1.0.0
---

# Reorganize Vault

Analyzes and reorganizes vault content. Always proposes a plan before touching any files.

## Vault Path

`/mnt/z/Users/nhang/Documents/Obsidian`

## Steps

1. **Scope** — is this full vault or a specific folder? Clarify if ambiguous.
2. **Analyze** — get full file tree: `find ~/obsidian -name "*.md" -not -path "*/.obsidian/*" | sort`
3. **Identify issues:**
   - Orphaned notes (no inbound links, not in a project folder)
   - Misplaced files (wrong domain folder)
   - Duplicate/near-duplicate filenames
   - Empty folders
4. **Propose reorganization plan** — list every move/rename as: `mv <from> → <to>`
5. **Wait for user approval** — do NOT move anything until confirmed
6. **Save rollback manifest** to `Reference/vault-reorg-YYYY-MM-DD.md` BEFORE executing
7. **Execute moves** — use Bash mv commands
8. **Confirm** — show final structure diff

## Rollback Manifest Format

```markdown
# Vault Reorg — YYYY-MM-DD

## Moves Made

| From | To |
|------|----|
| old/path.md | new/path.md |
```
