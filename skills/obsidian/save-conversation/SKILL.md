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
2. Extract the `## Project Taxonomy` section for folder paths — the `Vault path` column is the **canonical allow-list** of top-level folders. The optional `precedence` column ranks routes when more than one matches (lower number wins; absent → 100).
3. Match the conversation's dominant topics against the keywords in those sections — collect **every** matching candidate, not just the first.
4. If exactly one candidate matches above threshold, use it. If two or more match, run the **Cross-Domain Tiebreaker** below.

If `obsidian.local.md` does not exist, tell the user to run `/obsidian:setup` first and stop.

If the user provides a topic hint (e.g. "/obsidian:save WSL setup"), use it to override the keyword-based routing — look for the closest matching domain **that exists in the taxonomy**. The hint must resolve to a row already in `## Project Taxonomy`. If it does not, stop and tell the user:

> Topic hint `<hint>` did not match any allow-listed domain. Allow-listed domains: `<list>`. Either correct the hint or add a row to `## Project Taxonomy` via `/obsidian:setup`.

Never let a fuzzy hint create a new top-level folder.

## Cross-Domain Tiebreaker

When the keyword scan in step 2 produces **2+ candidate domains** (common for cross-cutting topics: career notes that touch a specific employer; finance notes that touch personal goals; dev notes that touch a specific repo), apply this tiebreaker before writing:

0. **Check the session cache first.** Maintain a mental map of `<topic-stem> → <chosen-domain>` for the current Claude Code session (use a code block in working memory or a dedicated section of your scratchpad). If the current note's topic-stem already appears in the cache, use the cached domain and skip steps 1–5. The cache is in-memory only; it resets between sessions.
1. **Sort candidates by `precedence`** (the optional column in `## Project Taxonomy`). Lower number wins; absent treated as 100.
2. **Pick the highest-precedence candidate** as the proposed target.
3. **Scan sibling candidates** for existing notes with overlapping slugs (use the same token Jaccard from "Same-Day Dedup Check" but across the whole sibling folder, not just same-day). If any sibling has matches scoring ≥ `dedup_jaccard_threshold`, surface them:
   > Topic also matched `<sibling-domain>` (precedence `<n>`); existing notes there: `<list>`. Routing to `<chosen>` (precedence `<m>`). Override?
4. **Remember the choice for the session** — once the user confirms or overrides, write `<topic-stem> → <chosen-domain>` into the in-memory cache from step 0. Do not re-prompt for the same topic-stem this session.
5. **No precedence column at all** in the taxonomy → fall back to: warn the user about the multi-match, list candidates, and ask once. Their reply seeds the in-memory cache (step 4).

This prevents the parallel-tree problem (e.g. `Career/`, `Awesome Motive/career/`, `Personal/Job Search/` all accumulating notes about the same job-search thread because each save resolved to a different route).

Mirror the precedence column in the example file's `## Project Taxonomy`. The setup wizard offers an optional precedence prompt — see `obsidian-setup`.

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
2. **Detect topic and collect candidates** — scan conversation context for domain keywords; collect **every** matching candidate, not just the first
3. **Resolve target folder** — if exactly one candidate matched, use it. If two or more matched, run the **Cross-Domain Tiebreaker** (see section above) to pick one. The result is the resolved target folder.
4. **Generate title** — create descriptive kebab-case title from topic, e.g. `2026-02-19-obsidian-vault-consolidation`
5. **Build content** — format conversation as structured markdown per template above (or use `Templates/session.md` from vault if it exists)
6. **Determine full path** — `<vault_path>/<target-folder>/<YYYY-MM-DD-title>.md`
7. **Validate allow-list** — `strict_domains` defaults to `true` when absent; only an explicit `false` skips validation. See "Allow-list Validation (strict_domains)" above. If the top-level folder is not allow-listed, refuse and surface the closest match. Do not create the folder. If routing landed in `Inbox/` because no clear domain matched, prompt for confirmation ("No clear domain match — routing to `Inbox/`. Confirm or supply a topic hint") rather than writing silently.
8. **Same-day dedup check** — see "Same-Day Dedup Check" below. Before writing, scan the **confirmed** target folder (after any Inbox redirect or topic-hint correction from step 7) for same-day notes and offer append vs new-file when an existing match scores above the threshold.
9. **Create parent dirs if needed** — `mkdir -p <vault_path>/<target-folder>` (only after validation passes)
10. **Write or append** — use Write tool for new files; use Edit tool to append a timestamped section when the user chose append mode in step 8.
11. **Confirm** — tell user where the file was saved (and whether it was a new file or an append)
12. **Open in GUI** — call `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <relative-path>`
13. **MOC-promotion prompt (post-save, soft)** — see "MOC-Promotion Prompt" below. After a successful new-file write, check whether the parent folder has accumulated 3+ notes sharing a topic stem. If so, prompt once to promote into a dedicated subfolder with a `README.md` index. Skip on append. Skip if the user previously declined promotion for this stem.

## Same-Day Dedup Check

Before writing a new note in the resolved target folder, check whether a same-day note covering the same topic already exists. This prevents same-day twin files like `2026-04-22-candid-vault-self-assessment.md` and `2026-04-22-vault-self-analysis.md`.

### Steps

1. **Glob the target folder** for `<YYYY-MM-DD>-*.md` where `<YYYY-MM-DD>` is today's date. Bash example:
   ```bash
   find "<vault_path>/<target-folder>" -maxdepth 1 -type f -name "$(date +%Y-%m-%d)-*.md" 2>/dev/null
   ```
2. **Score topic similarity** between the proposed kebab-case slug (the part after the date prefix in the new filename) and each existing same-day file's slug. Use **token Jaccard similarity**: split each slug on `-`, lowercase, **drop tokens that are purely numeric (e.g. `2026`, `04`, `1234`) or exactly one character (e.g. `a`, `v`, `x`)**. Keep 2-char tokens like `pr`, `om`, `wp`, `ai` — these carry signal in dev/work slugs. Then compute `|A ∩ B| / |A ∪ B|`.
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

## MOC-Promotion Prompt

After a successful new-file write, check whether the parent folder has grown a coherent cluster that deserves its own subfolder + index. **Soft prompt only — never auto-create.**

### Steps

1. **Skip conditions** — Skip immediately if any of:
   - The save was an append (not a new file).
   - The user has previously declined promotion for this topic-stem in the current session (track in the same in-memory cache as the Cross-Domain Tiebreaker, with a separate key prefix like `moc-declined:<stem>`).
   - The parent folder is already inside a per-idea subfolder (e.g. `Projects/Physics-AI-ML/DeCoN/notes/`) — promotion only fires at the *parent of loose notes*, not nested.
   - `moc_promotion: false` is set in `obsidian.local.md` frontmatter.

2. **Cluster detection** — In the parent folder (non-recursive), find all `.md` files whose slug shares ≥ 2 tokens after applying the same token filter from "Same-Day Dedup Check" (drop purely-numeric and single-character tokens). Identify the candidate **topic stem** using the precise rule in the "Tokenization for stem detection" section below — do not pick stem by length alone here.
   - Minimum cluster size: 3 (configurable via `moc_promotion_threshold` in config; default 3).
   - The new file just written counts toward the cluster.

3. **Prompt once** — if a cluster ≥ 3 is found, surface:
   > Folder `<parent>/` has accumulated 3+ notes sharing the topic stem `<stem>`:
   > - `<file-1>`
   > - `<file-2>`
   > - `<file-3>` (just written)
   >
   > Promote `<stem>` to its own subfolder with a `README.md` index?
   > - **yes** → move matching files into `<parent>/<Stem>/notes/` and create `<parent>/<Stem>/README.md` with a stub MOC linking each note
   > - **no** → leave files where they are, remember the decline so we don't ask again this session

4. **On accept**:
   - **Pre-move wikilink scan** — before any `mv`, grep the vault for each candidate file's wikilink form: `grep -rl "\[\[<filename-without-ext>\]\]" "<vault_path>" --include="*.md"` per file. If any references exist, surface them:
     > Promoting will break the following wikilinks (Obsidian will not auto-update them via shell `mv`):
     > - `<note-with-link>` → `[[<broken-target>]]`
     >
     > Continue anyway? (yes/no — recommend running Obsidian's "Update links on rename" manually after if you proceed)

     If the user declines on the link-warning prompt, treat as an MOC decline (cache it) and stop.
   - `mkdir -p "<parent>/<Stem>/notes"` — these writes operate under the already-validated parent folder and bypass the Step 7 allow-list check by design.
   - Move matching files: `mv "<parent>/<file-N>" "<parent>/<Stem>/notes/"` (preserves frontmatter — no content edits).
   - Write a stub `<parent>/<Stem>/README.md`:
     ```markdown
     ---
     date: <YYYY-MM-DD>
     type: moc
     tags: [moc, <stem>]
     ---

     # <Stem-title-cased>

     ## Notes

     - [[notes/<file-1>]]
     - [[notes/<file-2>]]
     - [[notes/<file-3>]]

     ## Related

     -
     ```
   - Confirm to user with the new paths.

5. **On decline**: write `moc-declined:<stem>` to the session cache and move on. Do not ask again this session.

### Tokenization for stem detection

Same filter as dedup: split slug on `-`, lowercase, drop tokens that are purely numeric (`2026`, `04`) or exactly one character (`a`, `v`, `x`). Keep 2-char tokens (`pr`, `om`, `wp`, `ai`).

**Stem selection (precise rule):**
1. For each filtered token, count the **number of distinct file-slugs in the candidate cluster that contain it** (not total occurrences across all files).
2. Pick the token with the highest distinct-file count. That token must appear in **every** file in the candidate cluster — otherwise the cluster isn't coherent enough to promote, abort the prompt.
3. **Tie-break:** if multiple tokens are tied on distinct-file count, pick the longest token (by character count). If still tied, pick alphabetically first. Always pick a single token, never a contiguous sequence — false-positive risk on overlapping tokens that happen to appear in different slug positions.

### Why

Idea folders accumulate loose notes without an index. By the time the user notices, the cluster is hard to navigate and links are missing — the 2026-05-09 vault reorg found 9 loose notes at `Projects/Physics-AI-ML/` that had grown around 3-4 latent ideas. A soft prompt at the right moment promotes the cluster before drift sets in.

This is **strictly opt-in per cluster**. Never move files without explicit confirmation. Never re-prompt for the same stem in the same session.

## Chapter Segmentation

If the conversation contains `#bookmark` markers, split into multiple notes — one per chapter.
If there are time gaps >30 min (visible from message timestamps), treat each segment as a separate note.

When segmentation produces multiple candidate files, run the Same-Day Dedup Check **per chapter** — each candidate file independently globs the target folder and prompts append vs new on a hit. Do not skip the dedup check for chapters 2..N.
