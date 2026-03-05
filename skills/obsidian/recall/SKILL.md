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
1. `mcp__plugin_claude-mem_mcp-search__search` with query = ticket number + keywords, limit 10
2. `mcp__plugin_claude-mem_mcp-search__timeline` on the most relevant result
3. `mcp__plugin_claude-mem_mcp-search__get_observations` for full details on filtered IDs

If claude-mem is unavailable or returns errors, note "claude-mem: unavailable" and continue with other sources.

## Step 3: Synthesize Report

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
