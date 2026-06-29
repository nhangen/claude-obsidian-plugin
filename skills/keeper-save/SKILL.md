---
name: keeper-save
description: Agent-facing entry point for filing or appending a structured note through the vault keeper. Triggers when another agent or skill needs to persist a note — findings, decisions, observations, research results, daily-log entries — into the vault without back-and-forth. Humans use /obsidian:ask instead. Validates the structured payload then dispatches the vault-librarian INSERT or APPEND; routing and templates are owned by the librarian.
version: 1.1.0
---

# keeper-save (Agent-Facing Vault Write)

File or append a structured note through the vault keeper. This is the
agent-facing door: humans use `/obsidian:ask`; agents and sub-skills use this.

Dispatches the existing `vault-librarian` INSERT/APPEND — routing, dedup, and
template selection are owned by the librarian. This skill does NOT re-implement
any of those; a keeper-saved note is identical to a librarian-filed one.

Two operations, selected by the `op` field (default `insert`):
- **INSERT** — file a new note (findings, decisions, observations).
- **APPEND** — add a timestamped section to an existing dated note (daily-log
  entries), creating it from the template if absent.

## Payload format

Write a temp file with this exact layout:

```
op: <optional — insert (default) | append>
title: <required for insert — note title>
folder_hint: <optional — target folder path, e.g. CEO/agents/hari-seldon>
type: <optional — note type, e.g. finding, decision, observation>
links: <optional — comma-separated wikilink targets, e.g. Note A, Note B>
date: <append: YYYY-MM-DD; resolves to the daily note for that date>
target: <append: explicit note path, e.g. Daily/2026-06-29.md>
section: <append, optional — section heading, e.g. ## 14:30 — Topic>
---
<body — required; everything after the --- line>
```

Header lines before `---`: `key: value` pairs. Order is not significant.
For `op: insert`, `title` and body are required. For `op: append`, body and at
least one of `date`/`target` are required (no `title` needed). An unknown `op`
is rejected, never coerced.
`links` values are normalized to `[[Name]]` wikilinks before dispatch.

## Steps

1. **Write the payload** to a temp file using the format above.

2. **Validate the payload.**
   Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/keeper-save-payload.sh` and run
   `kspayload_validate <payload-file>`. On failure it prints
   `keeper-save: missing required field: <title|body>` to stderr.
   Return the error to the caller and stop — do not write.

3. **Check vault staleness.**
   Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ask-staleness.sh"`; if it prints a
   line, surface it as a `⚠` banner before proceeding.

4. **Dispatch the vault-librarian.** Read `op` with
   `kspayload_field <payload-file> op` (empty means `insert`).

   For `insert` — call the `obsidian:vault-librarian` subagent with operation
   hint `INSERT`, passing:
   - `title` from `kspayload_field <payload-file> title`
   - `body` from `kspayload_body <payload-file>`
   - `folder_hint` from `kspayload_field <payload-file> folder_hint` (may be empty)
   - `type` from `kspayload_field <payload-file> type` (may be empty)
   - normalized links from `kspayload_links <payload-file>` (may be empty)

   For `append` — call the `obsidian:vault-librarian` subagent with operation
   hint `APPEND`, passing:
   - `target` from `kspayload_field <payload-file> target`, or `date` from
     `kspayload_field <payload-file> date` (the librarian resolves a date to
     its daily note)
   - `section` from `kspayload_field <payload-file> section` (may be empty)
   - `body` from `kspayload_body <payload-file>`

5. **Relay the committed path** back to the caller: what was written and where.
   If the librarian reports low-confidence routing or a near-duplicate, surface
   its question — do not auto-resolve it.
