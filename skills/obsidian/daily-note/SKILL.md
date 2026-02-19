---
name: obsidian-daily-note
description: Reads, creates, or appends to the Obsidian daily note. Triggers on phrases like "add to my daily note", "update today's note", "what's in my daily note", "open today's note", "daily note", "log this to today".
version: 1.0.0
---

# Daily Note Management

Manages the daily note in `Daily/YYYY-MM-DD.md`.

## Vault Path

`/mnt/z/Users/nhang/Documents/Obsidian/Daily/`

## Steps

### Read today's note:
1. `cat ~/obsidian/Daily/$(date +%Y-%m-%d).md` — if exists, return contents
2. If not exists, offer to create it

### Append to today's note:
1. Determine today's date: `date +%Y-%m-%d`
2. Check if file exists; create from template if not
3. Append content as a new section with timestamp
4. Confirm what was added

### Create today's note:
1. Copy template from `Daily/_Daily Template.md` if it exists
2. Replace `{{date}}` placeholder with today's date
3. Write to `Daily/$(date +%Y-%m-%d).md`
4. Open in GUI

## Append Format

When appending, add:
```markdown

## HH:MM — [Topic]

[Content]
```
