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
title: <required for insert — note title (also the INDEX/Session-Links link text)>
folder_hint: <optional — target folder path, e.g. CEO/agents/hari-seldon>
resolved: <optional — true: caller already routed + deduped; keeper writes to
           the resolved target as-is, skipping its own routing and dedup. Any
           other value / absent = keeper routes + dedups (folder_hint a hint).>
type: <optional — note type, e.g. finding, decision, observation>
links: <optional — comma-separated wikilink targets, e.g. Note A, Note B>
date: <append: YYYY-MM-DD; resolves to the daily note for that date>
target: <append: explicit note path, e.g. Daily/2026-06-29.md.
         insert+resolved: the full vault-relative path the caller resolved,
         e.g. Decisions/2026-06-29-my-note.md>
section: <append, optional — section heading, e.g. ## 14:30 — Topic>
session_link_date: <insert+resolved, optional — YYYY-MM-DD; adds a
                    `- [[title]]` entry under that daily note's ## Session Links>
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

4. **Route by op + resolution.** Read `op` (`kspayload_field <payload> op`;
   empty = insert). **Mechanical writes go straight to the keeper CLI — no
   subagent.** Only an *unresolved* insert needs the librarian's routing/dedup
   judgment. Resolve the vault once (read `vault_path` from the config that
   `${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh` prints) and write the
   body to a temp file: `kspayload_body <payload> > <body-temp>`.

   **`append`** → run the CLI directly:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/keeper" append --vault "$VAULT" \
     {--target "<target>" | --date "<date>"} --section "<section>" \
     --body-file "<body-temp>" [--init-file "<init-temp>"]
   ```
   For a `--date` append whose daily note may not exist, first render an
   `--init-file`: read `$VAULT/Daily/_Daily Template.md` (substitute `{{date}}`)
   if present, else a minimal `---\ndate: <date>\ntags: [daily]\n---\n\n# <date>\n`.

   **`insert` with `resolved: true`** → the caller already routed + deduped; run
   the CLI directly (no subagent):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/keeper" insert --vault "$VAULT" \
     --target "<target>" --body-file "<body-temp>" --title "<title>" \
     [--session-link-date "<session_link_date>"]
   ```
   Use the payload's `target` (the caller's resolved full path); if absent, build
   it from `folder_hint` + a kebab-cased `title`. Pass `--session-link-date` from
   the `session_link_date` field when set. The CLI writes the note, links the
   folder INDEX, and (if dated) adds the Session-Links entry.

   **`insert` without `resolved`** → dispatch the `obsidian:vault-librarian`
   subagent with hint `INSERT` (it routes, dedups, templates, links INDEX),
   passing `title`, body, `folder_hint`, `type`, and normalized
   `kspayload_links`. This is the only path that still spawns a subagent — the
   one that needs judgment.

5. **Relay the committed path** back to the caller: what was written and where.
   For an unresolved insert, if the librarian reports low-confidence routing or a
   near-duplicate, surface its question — do not auto-resolve it.
