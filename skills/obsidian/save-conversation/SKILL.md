---
name: obsidian-save-conversation
description: Exports the current Claude conversation to the Obsidian vault. Triggers on phrases like "save this to Obsidian", "export to obsidian", "document this session", "save our conversation", "write this up", "put this in obsidian". Formats the conversation as structured markdown, determines the correct project folder from context, and saves with a timestamped filename. Optionally opens the note in the Obsidian GUI.
version: 1.0.0
---

# Save Conversation to Obsidian

Exports the current Claude Code session to the Obsidian vault as a structured markdown note.

## Config

Read vault config from: `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`

Vault path: read `vault_path` field from `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`

## Routing Logic

Read routing rules from `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`:

1. Extract the `## Routing Rules` section from the config file
2. Extract the `## Project Taxonomy` section for folder paths
3. Match the conversation's dominant topics against the keywords in those sections
4. Use the matching target folder from the taxonomy

If `obsidian.local.md` does not exist, tell the user to run `/obsidian:setup` first and stop.

If the user provides a topic hint (e.g. "/obsidian:save WSL setup"), use it to override the keyword-based routing — look for the closest matching domain in the taxonomy.

## Output Format

Generate a markdown file with this structure:

```markdown
---
date: YYYY-MM-DD
time: HH:MM
session_type: [debugging|walkthrough|research|setup|conversation]
tags: [auto-detected tags]
source: claude-code
---

# [Descriptive Title]

## Summary

[2-4 sentence summary of what was accomplished/discussed]

## Key Findings / Decisions

- [Bullet point key takeaways]

## Details

[Full structured content — code blocks, explanations, steps taken]

## Related Notes

- [[link to related existing vault notes if any]]
```

## Steps

1. **Detect topic and routing** — scan conversation context for domain keywords, determine target folder
2. **Generate title** — create descriptive kebab-case title from topic, e.g. `2026-02-19-obsidian-vault-consolidation`
3. **Build content** — format conversation as structured markdown per template above
4. **Determine full path** — `<vault_path>/<target-folder>/<YYYY-MM-DD-title>.md`
5. **Create parent dirs if needed** — `mkdir -p <target-folder>`
6. **Write file** — use Write tool to save
7. **Confirm** — tell user where the file was saved
8. **Open in GUI** — call `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <relative-path>`

## Chapter Segmentation

If the conversation contains `#bookmark` markers, split into multiple notes — one per chapter.
If there are time gaps >30 min (visible from message timestamps), treat each segment as a separate note.
