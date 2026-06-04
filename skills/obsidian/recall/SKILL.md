---
name: obsidian-recall
description: Multi-source context recall. Searches Obsidian vault, git history, GitHub PRs, and claude-mem, then synthesizes a timeline report.
version: 1.1.0
---

# Recall

Synthesizes a report about past work from multiple data sources.

## Config

Resolve the config path dynamically (stable, version-independent), then read vault path and routing config from it:
```bash
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"
```
The resolver checks `$OBSIDIAN_LOCAL_MD`, then `${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`, then `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`. If it prints nothing, tell the user to run `/obsidian:setup` first and stop.

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

Three entry paths with concrete triggers. Each is independent — fire any that apply.

**Path E1: trace from the top flat-search hit.**

Trigger: Source D returned at least one observation.

```
graph_neighbors({ observation_id: <top hit id>, max_results: 30 })
```

Surface only these edge types: `produced_by` (same-session siblings), `depends_on` (causal upstream), `informed_by` (narrative-extracted causal), `continues` (cross-session arc). Do not show `relates_to` — upstream `graph_neighbors` (claude-mem-graph ≥ v0.2.3) filters it at the source; this client does not double-filter. If you see a `relates_to` row in output, the installed graph is older than v0.2.3 — silently discard and add a one-line note to the report so the user knows to upgrade.

**Path E2: file path lookup (exact match only).**

Trigger: the query contains a **literal file path** — a token with a `/` separator OR a filename ending in `.md` / `.ts` / `.tsx` / `.jsx` / `.py` / `.php` / `.sh` / `.go` / `.rs`.

```
graph_file_history({ file_path: "<the literal token from the query>" })
```

`graph_file_history` does **exact-match lookup** against the graph's `file:<path>` nodes — no substring, no basename, no glob. Only literal paths from the query work here. **Do NOT pass kebab-case skill names, repo slugs, or guessed directory names — they will silently return empty.**

**Path E3: cross-project graph search.**

Trigger when EITHER:
- (a) Source D returned 0 rows, OR
- (b) Source D's top hit's title (lowercased) shares no token of length ≥ 4 with the query keywords (lowercased, stopwords removed), OR
- (c) the query contains a kebab/snake_case identifier with 1+ separators (e.g. `pr-czar`, `branch-worktree-cleanup`, `mem_search`) that did NOT trigger Path E2.

```
graph_search({ task_description: "<original keywords>", max_sessions: 30, since_days: 365 })
```

Path E3 searches title, subtitle, narrative, text, facts, and concepts — different indexing from Source D's FTS, so it can surface observations Source D missed (e.g. when a skill/script name appears in a narrative but not a title). It's weaker than flat search for general keyword queries — that's why the trigger is conditional, not always-on.

If E2 returned exact file-history results, you can skip E3's (c) branch — you've already located the entry via file path.

If all three paths return empty, claude-mem-graph adds nothing for this query — proceed without it.

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
