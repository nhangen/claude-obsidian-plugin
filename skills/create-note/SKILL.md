---
name: create-note
description: Creates a new note, project folder, or page in the Obsidian vault. Triggers on phrases like "create a note about X", "start a new project for Y", "add a page for Z", "new obsidian note", "create project folder", "set up a new project in obsidian".
version: 1.3.0
---

# Create Note in Obsidian

Run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/capture-owner.py" status` first.
For stable MCP ownership, create single notes through `obsidian:keeper-save`'s
MCP branch after bounded remote routing/dedup. Do not run local allow-list or
vault commands. Project scaffolding is local-maintenance-only and unavailable
through the public note API; report that limitation without creating local
folders. Stop on disabled/draining ownership or an unreadable record. The local
procedure below applies only to stable legacy ownership.

Creates new notes or project structures in the vault.

Single notes and pages are filed through the **keeper-save** skill — the
keeper owns the write and INDEX linking; when routing is unresolved the
vault-librarian owns routing, the `## Project Taxonomy` allow-list, and dedup. This skill does not re-implement any of
those. Project scaffolding (a folder with README + subfolders) is the one
shape keeper-save's single-note INSERT cannot build, so that branch stays
native here.

## Steps

1. **Determine type** — single note, page in an existing project, or a new
   project folder (README + subfolders).

2. **Single note or page → file through keeper-save.**
   Invoke the `obsidian:keeper-save` skill with a payload:
   - `title` — the note title.
   - `body` — the starter content (use the Note Template below as the body if
     the user gave no content).
   - `folder_hint` — the topic/domain hint, or the existing project's folder
     path for a page. May be omitted; the librarian routes by the taxonomy.
   - `type` — `note` (or a vault-defined type if `VAULT.md` names one).
   - `links` — any related notes the user named.
   - `resolved: true` + `target` — only for a page inside an existing project
     folder whose full path you know. Perform the step 6 allow-list check
     (`allowlist_validate "<target>"`) first, then check the folder for a same-name note first; `resolved` promises the
     caller already routed and deduped. keeper-save then writes directly with
     no subagent. Otherwise omit both and let the librarian route.
   Relay the committed path keeper-save returns. If it surfaces a
   low-confidence-routing or near-duplicate question, pass it to the user —
   do not auto-resolve. **Stop here for this type.**

3. **New project folder → scaffold natively** (keeper-save does not build
   multi-folder structures). Continue with steps 4–9.

4. **Resolve vault path and conventions.**
   ```bash
   CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"
   VAULT_PATH=$(grep '^vault_path:' "$CONFIG" | sed 's/vault_path: //')
   ```
   If the resolver prints nothing (no config at `$OBSIDIAN_LOCAL_MD`,
   `${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`, or
   `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`), tell the user to run
   `/obsidian:setup` first and stop. If `VAULT.md` exists at the vault root,
   read it and follow any structure conventions it defines.

5. **Route to correct domain** — route per the canonical **## Routing Rules** in the resolved config (valid folders = `allowlist_list`; lowest `Precedence` wins on multi-match). Do not restate the rules here.

6. **Validate allow-list** — `strict_domains` defaults to `true` when absent; only an explicit `false` skips validation. When on, source the shared validator and call it — do not re-implement the parse/normalize/prefix/closest-match logic:

       . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/allowlist-validate.sh"
       if ! allowlist_validate "<resolved-target>"; then
         # allowlist_validate already printed the refusal to stderr; surface it and stop.
         # A refusal naming /obsidian:setup is a config fault — do not ask for a folder.
         exit 0
       fi

   Do not create unrecognized top-level folders.

7. **Create dirs and write** — `mkdir -p <path>` (only after validation passes), then write `README.md` + subfolders (Plans, Notes, Meetings as appropriate) with the Write tool.

8. **Confirm path** — tell user exactly where it was created.

9. **Open in GUI (opt-in)** — do not open by default. Read `auto_open` from `$CONFIG` (`grep '^auto_open:' "$CONFIG"`); it defaults to `false` when absent. Only when it is explicitly `true`, or the user explicitly asks to open/view, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/open-in-obsidian.sh <path>`.

## Note Template

```markdown
---
date: YYYY-MM-DD
tags: []
---

# Title

## Overview

## Notes

## Related

- [[]]
```

## Project README Template

```markdown
---
date: YYYY-MM-DD
type: project
status: active
---

# Project Name

## Goal

## Key Files

## Status
```
