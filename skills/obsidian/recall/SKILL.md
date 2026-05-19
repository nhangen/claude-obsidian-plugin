---
name: obsidian-recall
description: Multi-source context recall. Searches Obsidian vault, git history, GitHub PRs, and claude-mem, then synthesizes a timeline report.
version: 1.1.0
---

# Recall

Synthesizes a report about past work from multiple data sources.

## Config

Read vault path and routing config from: `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`

## Step 1: Parse Query

Extract from the natural language query:
- **Ticket numbers**: any `#NNNN` or bare number that looks like a ticket reference
- **Time range**: "last week", "yesterday", "in February", "since Monday", "this month"
  - Convert to concrete dates for git `--since`/`--until` and file date filtering
  - Default: last 14 days if no time range specified
- **Keywords**: everything remaining after extracting tickets and time ranges
- **Repo hint**: if query mentions a specific project name, use it to filter git/GitHub results
- **Vault conventions**: If `VAULT.md` exists at the vault root, read it for vault-specific structure and conventions. Follow any instructions it contains for search scoping, domain awareness, and pending questions.

## Step 2: Search All Sources

Run these in parallel where possible.

### Source A: Obsidian Vault

Use vault_path from config.

1. If ticket number present:
   - Grep for `ticket-<NNNN>` across `Projects/Development/` (matches tags in capture notes)
   - Also grep for `#NNNN` across the vault
2. If repo/project name mentioned:
   - Read files directly from `Projects/Development/<org>/<repo>/`
3. Grep for keywords across `Projects/` and `Daily/` directories
4. Check date-prefixed files in `Daily/` matching the time range
5. Read matching files (limit to first 10, prioritize capture notes and recent dates)

### Source B: Git History

Run via Bash from the current working directory:
```bash
git log --since="<start>" --until="<end>" --oneline --all
```
If ticket number present, filter by branch or message:
```bash
git log --since="<start>" --all --oneline | grep -i "<NNNN>"
```
Get file-level stats:
```bash
git log --since="<start>" --all --stat --format="%h %s" | head -80
```

If the current directory is not a git repo, ask the user which repo to search.

### Source C: GitHub PRs

```bash
gh pr list --state all --search="<ticket or keywords>" --limit 20
```

### Source D: claude-mem MCP

Use the 3-layer workflow:
1. `mcp__plugin_claude-mem_mcp-search__search` with query = ticket number + keywords, limit 10. **Pass `orderBy: "relevance"` explicitly** — the mem-search tool's default is `date_desc`, which hides older observations behind recent noise. Verified against claude-mem source: only the literal string `"relevance"` switches to FTS score; omitting the param falls through to date ordering.
2. `mcp__plugin_claude-mem_mcp-search__timeline` on the most relevant result
3. `mcp__plugin_claude-mem_mcp-search__get_observations` for full details on filtered IDs

If claude-mem is unavailable or returns errors, note "claude-mem: unavailable" and continue with other sources.

### Source E: claude-mem-graph MCP (causal tracing)

Two entry paths — run whichever applies. If neither produces useful neighbors, note "graph: no signal" and continue.

**Path E1: trace from the top flat-search hit.**

After Source D returns its top observation ID, call `mcp__plugin_claude-mem-graph_claude-mem-graph__graph_neighbors`:
```
graph_neighbors({ observation_id: <top hit id>, max_results: 30 })
```
Surface neighbors of these edge types only: `produced_by` (same-session siblings), `depends_on` (causal upstream), `informed_by` (narrative-extracted causal), `continues` (cross-session arc). **Discard `relates_to`** — generic-concept noise. Both upstream (graph_neighbors as of 2026-05-18) and this client should drop it; do not depend on either alone.

**Path E2: file-based seeding.** Independent entry point that does NOT depend on flat search finding the right node. Trigger if the query contains any of:

- a path-like token: contains `/`, or ends in `.md` / `.ts` / `.py` / `.php` / `.sh` / `.tsx` / `.jsx` / `.go` / `.rs`
- a kebab-case or snake_case token of 2+ separators: `branch-worktree-cleanup`, `discover-repos`, `pr-review-panel`, `optin-monster-app`, `mtf_builder_pipeline` — these are usually repo, skill, or script identifiers
- a multi-word phrase that maps to a known directory name in this vault or repo (e.g. "branch worktree cleanup" → `branch-worktree-cleanup`). When you see 3+ short lowercase words consecutively, try joining with `-` and check if a file or directory exists by that name.

For each candidate, call `graph_file_history`:
```
graph_file_history({ file_path: "<extracted token or resolved path>" })
```

If both paths return empty, claude-mem-graph adds nothing for this query — proceed without it.

**Path E3 (fallback): cross-project search.** If Source D returns 0 useful hits (all results irrelevant or empty), call `graph_search` once with the original keywords:
```
graph_search({ task_description: <keywords>, max_sessions: 30, since_days: 365 })
```
This is the "graph can find what flat search missed" last-resort path. Not for general use — it's weaker than flat search for most queries. Only invoke when Source D is empty.

## Step 3: Synthesize Report

When merging Source D (flat claude-mem) with Source E (graph), use flat hits to anchor the report and graph neighbors to expand the story arc. A `produced_by` sibling chain typically becomes a "Session Context" subsection; `depends_on` and `informed_by` chains become entries in "Timeline" or "Key Decisions"; `continues` edges become "Related Sessions".

Combine all results into this format:

```
# Recall: <Topic or Ticket #NNNN — Description>
Period: <start date> – <end date>

## Timeline
- <Day>: <summary of activity from all sources>
- <Day>: <next activity>

## Key Decisions
- <decisions extracted from vault notes and claude-mem>

## Session Context
- <debugging trails, approaches tried, architectural reasoning>
- <pulled from commit-capture notes and session saves>

## Files Changed (by frequency)
- <file path> (<N> commits)

## Open Threads
- <any open PRs, unresolved items, or in-progress work>

## Related
- [[vault note links]]
- PR #NNNN: <title>
```

### Synthesis Rules

- **Timeline**: Order events chronologically across all sources. One entry per day with activity.
- **Key Decisions**: Look for patterns in notes: "decided to", "chose", "went with", "instead of".
- **Session Context**: Pull from the "Session Context" sections in ticket notes. This is where the real value lives — the reasoning trail.
- **Files Changed**: Aggregate from git history, deduplicate, sort by commit frequency.
- **Open Threads**: Check if PRs are still open, if vault notes mention unfinished work.
- **Related**: Wiki-link to any vault files found. List PRs by number and title.

## Step 4: Output

Print the report directly to terminal.

Do NOT save to vault unless the user explicitly asks. If they do, write to `Projects/Development/recalls/<YYYY-MM-DD>-<topic>.md`.
