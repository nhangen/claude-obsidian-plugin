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
2. Extract the `## Project Taxonomy` section for folder paths — the `Vault path` column is the **canonical allow-list** of top-level folders
3. Match the conversation's dominant topics against the keywords in those sections
4. Use the matching target folder from the taxonomy

If `obsidian.local.md` does not exist, tell the user to run `/obsidian:setup` first and stop.

If the user provides a topic hint (e.g. "/obsidian:save WSL setup"), use it to override the keyword-based routing — look for the closest matching domain **that exists in the taxonomy**. The hint must resolve to a row already in `## Project Taxonomy`. If it does not, stop and tell the user:

> Topic hint `<hint>` did not match any allow-listed domain. Allow-listed domains: `<list>`. Either correct the hint or add a row to `## Project Taxonomy` via `/obsidian:setup`.

Never let a fuzzy hint create a new top-level folder.

## Allow-list Validation (strict_domains)

`strict_domains` defaults to **`true`** when the field is absent from the config frontmatter. Treat the field as opt-out, not opt-in. Only `strict_domains: false` (explicit) skips validation.

When strict mode is on, validate the resolved target before any write:

1. Parse the `## Project Taxonomy` table; collect every value in the `Vault path` column as the canonical allow-list (e.g. `Projects/Development/`, `Daily/`, `Inbox/`).
2. Compute the resolved target's **top-level prefix** — i.e. the path up to and including the first allow-listed root match. Dated subfolders and per-repo namespacing *under* an allow-listed root are valid (e.g. `Projects/Development/nhangen/foo/2026-05-09.md` is fine because `Projects/Development/` is allow-listed).
3. If no allow-list entry is a prefix of the resolved target, **refuse to write**. Surface the closest match (Levenshtein on the top-level component) and tell the user:

   > Refusing to write to `<target>` — top-level folder is not in the allow-list. Closest match: `<closest>`. Either correct the topic hint, or add `<target-toplevel>` to `## Project Taxonomy` in `obsidian.local.md` (or rerun `/obsidian:setup`).

4. Do **not** create the unrecognized folder. The taxonomy is the only place new top-level folders get added.

If `strict_domains: false`, skip this validation.

Why this matters: without strict validation, a typo'd hint silently creates an alias folder (e.g. `AM/` alongside `Awesome Motive/`) that fragments the vault over time. Failure-mode reference: `enum-config-typo-fallback`.

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

1. **Check vault conventions** — if `VAULT.md` exists at the vault root, read it for vault-specific conventions (e.g., session template, domain folders, linking rules)
2. **Detect topic and routing** — scan conversation context for domain keywords, determine target folder
3. **Generate title** — create descriptive kebab-case title from topic, e.g. `2026-02-19-obsidian-vault-consolidation`
4. **Build content** — format conversation as structured markdown per template above (or use `Templates/session.md` from vault if it exists)
5. **Determine full path** — `<vault_path>/<target-folder>/<YYYY-MM-DD-title>.md`
6. **Validate allow-list** — `strict_domains` defaults to `true` when absent; only an explicit `false` skips validation. See "Allow-list Validation (strict_domains)" above. If the top-level folder is not allow-listed, refuse and surface the closest match. Do not create the folder. If routing landed in `Inbox/` because no clear domain matched, prompt for confirmation ("No clear domain match — routing to `Inbox/`. Confirm or supply a topic hint") rather than writing silently.
7. **Create parent dirs if needed** — `mkdir -p <vault_path>/<target-folder>` (only after validation passes)
8. **Write file** — use Write tool to save
9. **Confirm** — tell user where the file was saved
10. **Open in GUI** — call `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <relative-path>`

## Chapter Segmentation

If the conversation contains `#bookmark` markers, split into multiple notes — one per chapter.
If there are time gaps >30 min (visible from message timestamps), treat each segment as a separate note.
