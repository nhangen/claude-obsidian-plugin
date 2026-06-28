---
name: keeper-save
description: Agent-facing entry point for filing a structured note through the vault keeper. Triggers when another agent or skill needs to persist a note — findings, decisions, observations, research results — into the vault without back-and-forth. Humans use /obsidian:ask instead. Validates the structured payload then dispatches the vault-librarian INSERT; routing and templates are owned by the librarian.
version: 1.0.0
---

# keeper-save (Agent-Facing Vault Write)

File a structured note through the vault keeper. This is the agent-facing door:
humans use `/obsidian:ask`; agents and sub-skills use this.

Dispatches the existing `vault-librarian` INSERT — routing, dedup, and template
selection are owned by the librarian. This skill does NOT re-implement any of
those; a keeper-saved note is identical to a librarian-filed one.

## Payload format

Write a temp file with this exact layout:

```
title: <required — note title>
folder_hint: <optional — target folder path, e.g. CEO/agents/hari-seldon>
type: <optional — note type, e.g. finding, decision, observation>
links: <optional — comma-separated wikilink targets, e.g. Note A, Note B>
---
<body — required; everything after the --- line>
```

Header lines before `---`: `key: value` pairs. Order is not significant.
`title` and body are required; all other fields are optional.
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

4. **Dispatch the vault-librarian INSERT.**
   Call the `vault-librarian` subagent with operation hint `INSERT`, passing:
   - `title` from `kspayload_field <payload-file> title`
   - `body` from `kspayload_body <payload-file>`
   - `folder_hint` from `kspayload_field <payload-file> folder_hint` (may be empty)
   - `type` from `kspayload_field <payload-file> type` (may be empty)
   - normalized links from `kspayload_links <payload-file>` (may be empty)

5. **Relay the committed path** back to the caller: what was written and where.
   If the librarian reports low-confidence routing or a near-duplicate, surface
   its question — do not auto-resolve it.
