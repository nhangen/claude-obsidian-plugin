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
2. Normalize both the allow-list entries and the resolved target before comparison: strip any trailing `/`, and lowercase both sides. The on-disk filesystem is often case-insensitive (macOS HFS+, default APFS); the prompt comparison must match.
3. Compute the resolved target's **top-level prefix** — i.e. the path up to and including the first allow-listed root match. Dated subfolders and per-repo namespacing *under* an allow-listed root are valid (e.g. `Projects/Development/nhangen/foo/2026-05-09.md` is fine because `Projects/Development/` is allow-listed).
4. If no normalized allow-list entry is a prefix of the normalized target, **refuse to write**. Surface the closest match (Levenshtein on the top-level component, in the original casing from the taxonomy) and tell the user:

   > Refusing to write to `<target>` — top-level folder is not in the allow-list. Closest match: `<closest>`. Either correct the topic hint, or add `<target-toplevel>` to `## Project Taxonomy` in `obsidian.local.md` (or rerun `/obsidian:setup`).

5. Do **not** create the unrecognized folder. The taxonomy is the only place new top-level folders get added.

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
7. **Same-day dedup check** — see "Same-Day Dedup Check" below. Before writing, scan the **confirmed** target folder (after any Inbox redirect or topic-hint correction from step 6) for same-day notes and offer append vs new-file when an existing match scores above the threshold.
8. **Create parent dirs if needed** — `mkdir -p <vault_path>/<target-folder>` (only after validation passes)
9. **Write or append** — use Write tool for new files; use Edit tool to append a timestamped section when the user chose append mode in step 7.
10. **Confirm** — tell user where the file was saved (and whether it was a new file or an append)
11. **Open in GUI** — call `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <relative-path>`

## Same-Day Dedup Check

Before writing a new note in the resolved target folder, check whether a same-day note covering the same topic already exists. This prevents same-day twin files like `2026-04-22-candid-vault-self-assessment.md` and `2026-04-22-vault-self-analysis.md`.

### Steps

1. **Glob the target folder** for `<YYYY-MM-DD>-*.md` where `<YYYY-MM-DD>` is today's date. Bash example:
   ```bash
   find "<vault_path>/<target-folder>" -maxdepth 1 -type f -name "$(date +%Y-%m-%d)-*.md" 2>/dev/null
   ```
2. **Score topic similarity** between the proposed kebab-case slug (the part after the date prefix in the new filename) and each existing same-day file's slug. Use **token Jaccard similarity**: split each slug on `-`, lowercase, **drop tokens that are purely numeric (e.g. `2026`, `04`) or a single character**. Keep 2-char tokens like `pr`, `om`, `wp`, `ai` — these carry signal in dev/work slugs. Then compute `|A ∩ B| / |A ∪ B|`.
3. **If the highest score is ≥ 0.4**, treat as a likely match and prompt the user:
   > Same-day note already exists: `<existing-path>` (similarity: `<score>`).
   > - **append** → add `## HH:MM — <new-topic>` section to the existing file
   > - **new** → write the proposed new file anyway
   > Choose: append / new
4. **Append mode**:
   - Read the existing file with the Read tool.
   - Use the Edit tool to insert a new section at the end (after the existing content, before any trailing whitespace). The new section starts with an h2 header: `## HH:MM — <Title>` (24h local time). The h2 header itself stays at h2 — do **not** demote it to h3.
   - Preserve frontmatter exactly as-is — do not edit the `---` fenced block.
   - Inside the new `## HH:MM — <Title>` section, the sub-blocks (`Summary`, `Key Findings / Decisions`, `Details`, `Related Notes`) are written as **`###` (h3) headings**, since they are children of the h2 timestamp section. Do not nest deeper than h3.
5. **New mode**: proceed with the original Write to a new file. Check for filename collision with `test -f "<full-path>"` before writing; if true, append `-2`, `-3`, etc. and recheck until the path is free. (Collisions only happen when two saves run within the same minute against the same slug.)
6. **No match (highest < 0.4)**: skip the prompt and proceed with Write.

### Threshold

`0.4` is the default. Override per-vault by setting `dedup_jaccard_threshold: 0.5` (or any float 0.0–1.0) in `obsidian.local.md` frontmatter. Set to `0.0` to always prompt; set to `1.0` to disable the check.

### Why

Recent vault reorg surfaced same-day twin notes that had to be manually merged. The skill writes a new file even when an existing same-day note covers the same ground because it never checks before writing. Globbing the target folder costs ~1 ms; the merge cost (manual or via the vault-organizer agent) is much higher.

## Chapter Segmentation

If the conversation contains `#bookmark` markers, split into multiple notes — one per chapter.
If there are time gaps >30 min (visible from message timestamps), treat each segment as a separate note.

When segmentation produces multiple candidate files, run the Same-Day Dedup Check **per chapter** — each candidate file independently globs the target folder and prompts append vs new on a hit. Do not skip the dedup check for chapters 2..N.
