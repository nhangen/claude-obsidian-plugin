---
name: save-conversation
description: Exports the current Claude conversation to the Obsidian vault. Triggers on phrases like "save this to Obsidian", "export to obsidian", "document this session", "save our conversation", "write this up", "put this in obsidian". Formats the conversation as structured markdown, determines the correct project folder from context, and saves with a timestamped filename. Optionally opens the note in the Obsidian GUI.
version: 1.2.0
---

# Save Conversation to Obsidian

Exports the current Claude Code session to the Obsidian vault as a structured markdown note.

This skill owns the **cognition** — session-intent inference, routing
(precedence tiebreaker + cross-domain cache), same-day dedup, research-substrate
detection, MOC clustering, chapter segmentation — and then hands the actual
**write** to the keeper (`obsidian:keeper-save`). It does not write note files
directly. The keeper is the sole writer; this skill resolves the target and
passes a `resolved: true` payload so the keeper writes it as-is without
re-routing or re-deduping. The one exception is MOC-promotion *file moves*, which
remain native (structural reorg is the vault-organizer's domain, not a note-write).

## Config

Resolve the config path dynamically — it lives at a stable, version-independent
location so plugin updates never strand it:

```bash
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"
```

This returns the first config that exists among `$OBSIDIAN_LOCAL_MD`,
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`, and
`${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`. Read `vault_path` and all routing
config from `$CONFIG`.

## Routing Logic

Route per the canonical **## Routing Rules** in the resolved config (valid folders = `allowlist_list`; lowest `Precedence` wins on multi-match). Do not restate the rules here.

If exactly one candidate matches above threshold, use it. If two or more match, run the **Cross-Domain Tiebreaker** below.

If the resolver prints nothing (no config exists at any location), tell the user to run `/obsidian:setup` first and stop.

If the user provides a topic hint (e.g. "/obsidian:save WSL setup"), use it to override the keyword-based routing — look for the closest matching domain **that exists in the taxonomy**. The hint must resolve to a row already in `## Project Taxonomy`. If it does not, stop and tell the user:

> Topic hint `<hint>` did not match any allow-listed domain. Allow-listed domains: `<list>`. Either correct the hint or add a row to `## Project Taxonomy` via `/obsidian:setup`.

Never let a fuzzy hint create a new top-level folder.

## Session Intent and Capture Action Inference

Before folder routing, infer two separate concepts from concrete transcript signals:

```yaml
session_intent:
  value: execution | research | planning | reflection | operations | scratch
  confidence: high | medium | low
  score: 0.0-1.0
  evidence:
    - concrete signal from transcript

capture_action:
  value: none | daily_only | project_note | substrate_update | decision_record
  confidence: high | medium | low
  score: 0.0-1.0
  evidence:
    - concrete signal from transcript
```

Intent describes what happened; capture action describes what durable update is warranted. Keep them separate because an `execution` session can still produce `substrate_update` evidence when it tests an active research claim.

### Intent Values

- `execution` — code/work/task session; produced or changed artifacts.
- `research` — papers, synthesis, claims, experiments, literature, source-backed comparisons.
- `planning` — roadmap, spec, decision analysis, implementation plan, project sequencing.
- `reflection` — trajectory, positioning, identity, personal synthesis.
- `operations` — customer/admin/business/accounting/course logistics.
- `scratch` — casual/trivial/non-durable conversation.

### Capture Action Values

- `none` — no durable capture.
- `daily_only` — daily-scoped note or lightweight daily mention only.
- `project_note` — normal project/session note.
- `substrate_update` — research-substrate claim/evidence/literature/experiment update is warranted.
- `decision_record` — durable decision or plan record is warranted.

## Research Substrate Check

For every save, ask: did this session create, weaken, support, or test a research claim?

Record the answer in frontmatter:

```yaml
research_state_change: none | supports_claim | weakens_claim | new_claim | new_experiment | new_evidence
substrate_object: "[[Projects/Physics-AI-ML/Research-Substrate/<type>/<slug>]]"
```

Use `research_state_change: none` and `substrate_object: ""` when the session did not change research state. Do this even for execution and planning sessions.

When `research_state_change` is not `none`, create or update one small object under `Projects/Physics-AI-ML/Research-Substrate/` and link it from the session note. Pick the smallest accurate object type:

- `claims/` for durable claims that can be supported, weakened, or invalidated.
- `experiments/` for tests, benchmarks, protocols, or validation plans.
- `evidence/` for repo runs, audits, result summaries, reproduced failures, or artifacts.
- `literature/` for papers and source-backed frontier markers.

**File it through the keeper, with a dedup pre-step.** Before writing, glob
`Research-Substrate/<type>/` for an existing object on the same claim/slug; if
one matches, update that object rather than creating a twin. Then hand the
create-or-update to `obsidian:keeper-save` with `op: insert`, `resolved: true`,
`folder_hint: Projects/Physics-AI-ML/Research-Substrate/<type>`,
`title: <slug>`, `body: <the object>`. The dedup pre-step is required because
`resolved: true` skips the keeper's own dedup and this skill has no other
substrate dedup — without it, duplicate claims/evidence accumulate silently.

If `capture_action: substrate_update`, the research state change cannot be `none`, and `substrate_object` must point to the object created or updated. If an execution session tests an active claim, keep `session_intent: execution`; set `research_state_change` to the actual claim/evidence effect.

### Scoring and Confirmation

Use concrete signals, not vibe: user verbs, referenced artifacts, outputs produced, explicit destination hints, and domain terms. Explicit user instructions win.

Default thresholds:

- High confidence: top score >= `0.70` and margin over next plausible option >= `0.15`.
- Medium confidence: score >= `0.45` but close margin or mixed evidence.
- Low confidence: below `0.45`.

Ask only when ambiguity changes the durable action. Do not ask for routine high-confidence routing.

Examples:

- User asks to read papers and compare to current work → `research + substrate_update`.
- User asks to fix a PR → `execution + project_note`; add substrate evidence only when an active claim is directly affected.
- User asks for roadmap/spec → `planning + project_note` or `decision_record` when an actual decision is made.
- User asks to leave an NRX/customer/admin note → `operations + project_note`.
- Casual chat with no durable outcome → `scratch + none`.

If top intent/action are close and the durable result differs, ask:

> I infer this as `<intent> + <action>` because `<evidence>`. The other plausible capture is `<alternate>`. Should this be `<option A>` or `<option B>`?

For non-interactive autosave paths where asking is impossible, write the safer note and set `capture_needs_confirmation: true` in frontmatter.

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

Mirror the precedence column in the example file's `## Project Taxonomy`. The setup wizard offers an optional precedence prompt — see `obsidian:setup`.

## Allow-list Validation (strict_domains)

`strict_domains` defaults to **`true`** when the field is absent from the config frontmatter. Treat the field as opt-out, not opt-in. Only `strict_domains: false` (explicit) skips validation.

When strict mode is on, validate the resolved target:

Source the shared validator and call it — do not re-implement the parse/normalize/prefix logic:

    . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/allowlist-validate.sh"
    if ! allowlist_validate "<target>"; then
      # allowlist_validate printed the refusal + closest match to stderr; surface it and stop.
      exit 0
    fi

`allowlist_validate` reads the `## Project Taxonomy` table as the canonical allow-list, normalizes case, matches the target's top-level prefix (dated subfolders and per-repo namespacing under a root are valid), and on failure prints the closest match. Do not create unrecognized top-level folders.

If `strict_domains: false`, skip this validation.

Why this matters: without strict validation, a typo'd hint silently creates an alias folder (e.g. `AM/` alongside `Awesome Motive/`) that fragments the vault over time. Failure-mode reference: `enum-config-typo-fallback`.

## Output Format

Generate a markdown file with this structure:

```markdown
---
date: YYYY-MM-DD
time: HH:MM
session_type: [debugging|walkthrough|research|setup|conversation]
session_intent: [execution|research|planning|reflection|operations|scratch]
session_intent_score: 0.0-1.0
session_intent_confidence: [high|medium|low]
capture_action: [none|daily_only|project_note|substrate_update|decision_record]
capture_action_score: 0.0-1.0
capture_action_confidence: [high|medium|low]
capture_needs_confirmation: false
research_state_change: [none|supports_claim|weakens_claim|new_claim|new_experiment|new_evidence]
substrate_object: "[[optional substrate object]]"
tags: [auto-detected tags]
source: claude-code
---

# [Descriptive Title]

## Summary

[2-4 sentence summary of what was accomplished/discussed]

## Capture Inference

- **Session intent:** `<value>` (`<confidence>`, `<score>`)
- **Capture action:** `<value>` (`<confidence>`, `<score>`)
- **Research state change:** `<value>`
- **Substrate object:** `<wikilink or none>`
- **Evidence:**
  - [Concrete signal]
  - [Concrete signal]

## Key Findings / Decisions

- [Bullet point key takeaways]

## Details

[Full structured content — code blocks, explanations, steps taken]

## Related Notes

- [[link to related existing vault notes if any]]
```

## Steps

1. **Check vault conventions** — if `VAULT.md` exists at the vault root, read it for vault-specific conventions (e.g., session template, domain folders, linking rules)
2. **Infer intent and capture action** — assign `session_intent`, `capture_action`, confidence, scores, and evidence bullets. Ask only when ambiguity changes the durable action.
3. **Infer research state change** — assign `research_state_change` and `substrate_object`. Create/update the substrate object when the value is not `none`.
4. **Detect topic and collect candidates** — scan conversation context for domain keywords; collect **every** matching candidate, not just the first
5. **Resolve target folder** — if exactly one candidate matched, use it. If two or more matched, run the **Cross-Domain Tiebreaker** (see section above) to pick one. The result is the resolved target folder.
6. **Generate title** — create descriptive kebab-case title from topic, e.g. `2026-02-19-obsidian-vault-consolidation`
7. **Build content** — format conversation as structured markdown per template above (or use `Templates/session.md` from vault if it exists)
8. **Determine full path** — `<vault_path>/<target-folder>/<YYYY-MM-DD-title>.md`
9. **Validate allow-list** — `strict_domains` defaults to `true` when absent; only an explicit `false` skips validation. See "Allow-list Validation (strict_domains)" above. If the top-level folder is not allow-listed, refuse and surface the closest match. Do not create the folder. If routing landed in `Inbox/` because no clear domain matched, prompt for confirmation ("No clear domain match — routing to `Inbox/`. Confirm or supply a topic hint") rather than writing silently.
10. **Same-day dedup check** — see "Same-Day Dedup Check" below. Before writing, scan the **confirmed** target folder (after any Inbox redirect or topic-hint correction from step 7) for same-day notes and offer append vs new-file when an existing match scores above the threshold.
11. **Write through the keeper.** The keeper creates parent dirs, applies the
    template, writes the file, and links the INDEX — this skill does not `mkdir`
    or `Write` a note directly.
    - **New file** → invoke `obsidian:keeper-save` with `op: insert`,
      `resolved: true`, `target: <target-folder>/<YYYY-MM-DD-title>.md` (the full
      path resolved in steps 5/8), `title: <YYYY-MM-DD-title>` (the filename stem
      — the resolvable INDEX/Session-Links link text), `body: <the built session
      note>`, `links`, and `session_link_date: <today YYYY-MM-DD>`. `resolved:
      true` is correct because steps 2–10 already did the routing and same-day
      dedup. `session_link_date` preserves the daily `## Session Links` entry the
      librarian used to add implicitly — keeper-save routes this straight to
      `keeper insert` (no subagent).
    - **Append (same-day twin)** → invoke `obsidian:keeper-save` with
      `op: append`, `target: <the twin file from the Same-Day Dedup Check>`,
      `section: ## HH:MM — <Title>`, and `body: <the FULL h3 sub-block
      structure>` (see Same-Day Dedup Check "Append mode" for the exact body).
12. **Confirm** — relay the path the keeper returns (new file or append).
13. **Open in GUI (opt-in)** — do not open the note by default. Read `auto_open` from `$CONFIG` (`grep '^auto_open:' "$CONFIG"`); it defaults to `false` when absent. Only when it is explicitly `true`, or the user explicitly asks to open/view the saved note, call `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <relative-path>`.
14. **MOC-promotion prompt (post-save, soft)** — see "MOC-Promotion Prompt" below. After a successful new-file write, check whether the parent folder has accumulated 3+ notes sharing a topic stem. If so, prompt once to promote into a dedicated subfolder with a `README.md` index. Skip on append. Skip if the user previously declined promotion for this stem.

## Same-Day Dedup Check

Before writing a new note in the resolved target folder, check whether a same-day note covering the same topic already exists. This prevents same-day twin files like `2026-04-22-candid-vault-self-assessment.md` and `2026-04-22-vault-self-analysis.md`.

### Steps

1. Source the shared scanner and call it:

       . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/dedup-scan.sh"
       dedup_same_day "<vault>/<target-folder>" "$(date +%Y-%m-%d)" "<proposed-slug>" "${dedup_jaccard_threshold:-0.4}"

   `dedup_same_day` globs today's notes in the folder, scores each slug's token Jaccard against the proposed slug (via the single `tokenize_slug`), and echoes `path<TAB>score` for the best match at or above the threshold, or nothing.
2. If it echoed a match, prompt the user (append vs new), as below.
3. **If the highest score is ≥ 0.4**, treat as a likely match and prompt the user:
   > Same-day note already exists: `<existing-path>` (similarity: `<score>`).
   > - **append** → add `## HH:MM — <new-topic>` section to the existing file
   > - **new** → write the proposed new file anyway
   > Choose: append / new
4. **Append mode** — hand the section-write to the keeper (do not `Edit` the
   file directly):
   - Build the section body: an `## HH:MM — <Title>` h2 timestamp header (24h
     local; stays h2, never demoted), then the sub-blocks (`Summary`,
     `Key Findings / Decisions`, `Details`, `Related Notes`) as **`###` (h3)
     headings** — children of the timestamp section, never nested deeper than h3.
   - Invoke `obsidian:keeper-save` with `op: append`, `target: <the matched
     same-day file>`, `section: ## HH:MM — <Title>`, and `body: <the h3
     sub-block structure built above>`. The keeper appends verbatim after the
     existing content and preserves the frontmatter; it does not reconstruct the
     h3 nesting, so the full structure must be in `body`. The target already
     exists, so the keeper's create-on-absent does not fire.
5. **New mode**: route the new-file write through the keeper per step 11 of the
   main Steps (`op: insert`, `resolved: true`). Before handing off, check for a
   filename collision with `test -f "<full-path>"`; if true, append `-2`, `-3`,
   etc. and recheck until the path is free, then pass the free path's folder as
   `folder_hint`. (Collisions only happen when two saves run within the same
   minute against the same slug.)
6. **No match (highest < 0.4)**: skip the prompt and proceed with the keeper
   INSERT (step 11, new file).

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

Tokenize every candidate slug with the shared `tokenize_slug` (source `dedup-scan.sh`) — the same tokenizer the dedup check uses, so the two never diverge:

    . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/dedup-scan.sh"
    tokenize_slug "<slug>"

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
