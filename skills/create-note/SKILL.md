---
name: create-note
description: Creates a new note, project folder, or page in the Obsidian vault. Triggers on phrases like "create a note about X", "start a new project for Y", "add a page for Z", "new obsidian note", "create project folder", "set up a new project in obsidian".
version: 1.1.0
---

# Create Note in Obsidian

Creates new notes or project structures in the vault.

Single notes and pages are filed through the **keeper-save** skill — the
vault-librarian owns routing, the `## Project Taxonomy` allow-list, the
template, dedup, and INDEX linking. This skill does not re-implement any of
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

5. **Route to correct domain** — use routing logic from `obsidian:save-conversation` skill.

6. **Validate allow-list** — `strict_domains` defaults to `true` when absent from the config frontmatter; only an explicit `false` skips validation. When on:
   - Parse the `## Project Taxonomy` table from `$CONFIG` (resolved above); the `Vault path` column is the canonical allow-list of top-level folders.
   - Normalize both the allow-list entries and the resolved target before comparison: strip any trailing `/`, and lowercase both sides (macOS HFS+/default APFS is case-insensitive).
   - Compute the resolved target's top-level prefix (path up to and including the first allow-listed root match). Dated subfolders and per-repo namespacing *under* an allow-listed root are valid.
   - If no normalized allow-list entry is a prefix of the normalized target, **refuse to write**. Surface the closest match (Levenshtein on the top-level component, original casing from the taxonomy) and tell the user:
     > Refusing to write to `<target>` — top-level folder is not in the allow-list. Closest match: `<closest>`. Either correct the topic hint, or add `<target-toplevel>` to `## Project Taxonomy` in `obsidian.local.md` (or rerun `/obsidian:setup`).
   - Do not create unrecognized top-level folders. Topic hints that fuzzy-match must themselves resolve to an existing taxonomy row.

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
