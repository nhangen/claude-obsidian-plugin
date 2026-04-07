---
name: obsidian-setup
description: First-time setup wizard for the Obsidian plugin. Guides the user through configuring vault path, domain taxonomy, and routing rules, then writes obsidian.local.md. Triggers on "/obsidian:setup", "set up obsidian", "configure obsidian plugin", "obsidian first run".
version: 1.0.0
---

# Obsidian Plugin Setup

Interactive first-run wizard. Writes `obsidian.local.md` from user answers so routing works correctly for their vault.

## When to Run

- User invokes `/obsidian:setup`
- `obsidian.local.md` does not exist (first install)
- User says their routing is going to the wrong folder

## Steps

### 1. Check for Existing Config

Read `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md` if it exists. If found, tell the user:

> `obsidian.local.md` already exists. Running setup will overwrite it. Continue? (yes/no)

If they say no, stop.

### 2. Ask for Vault Path

Ask:

> What is the absolute path to your Obsidian vault?
> (e.g. `/Users/yourname/Documents/Obsidian` or `~/Documents/MyVault`)

Validate:
- Expand `~` to the full home path
- Check the directory exists with the Read tool (attempt to read any file in it, or just verify path)
- If it doesn't exist, tell the user and ask again

### 3. Ask for Domains

Ask:

> What top-level domains (project areas) does your vault have?
> List them comma-separated — these become your routing targets.
>
> Examples:
> - `Work, Personal, Learning`
> - `Development, Research, Journal`
> - `Client-A, Client-B, Internal`

Parse the comma-separated list into a clean array (trim whitespace, title-case optional).

### 4. Ask for Keywords per Domain

For each domain, ask:

> What keywords should route notes to **[Domain]**?
> (comma-separated — topic words that signal this domain)
>
> Example for "Development": `code, git, bug, deploy, api, claude, plugin`

Collect keywords for each domain.

### 5. Ask for Daily Notes Path

Ask:

> Where are your daily notes? (relative to vault root)
> Default: `Daily/` — press Enter to accept, or type a custom path.

### 6. Ask for Inbox Path

Ask:

> Where should ambiguous notes go? (relative to vault root)
> Default: `Inbox/` — press Enter to accept.

### 7. Write obsidian.local.md

Build and write the config file to `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`:

```markdown
---
vault_path: <expanded absolute path>
vault_name: <last path component>
auto_save: true
auto_open: true
time_gap_minutes: 30
smart_detect: true
domains:
<  - Domain1>
<  - Domain2>
---

# Obsidian Plugin Config

Vault is at `<vault_path>`.

## Project Taxonomy

| Domain | Vault path | Notes |
|--------|-----------|-------|
<| Domain1 | Projects/Domain1/ | |>
<| Domain2 | Projects/Domain2/ | |>
| Daily | <daily_path> | |

## Routing Rules

<- Keywords "<kw1>, <kw2>" → Projects/Domain1/>
<- Keywords "<kw3>, <kw4>" → Projects/Domain2/>
- Keywords "daily, journal, today" → <daily_path>
- Ambiguous → <inbox_path> (with #needs-filing tag)
```

Substitute the user's actual answers. The `Projects/<Domain>/` path convention is the default — note it can be customized.

### 8. Confirm

Tell the user:

> Config written to `obsidian.local.md`.
>
> **Vault:** `<path>`
> **Domains:** Domain1 → `Projects/Domain1/`, Domain2 → `Projects/Domain2/`
> **Daily notes:** `<daily_path>`
> **Fallback (ambiguous):** `<inbox_path>`
>
> To change any of this, edit `obsidian.local.md` directly or re-run `/obsidian:setup`.

## Notes

- Vault path with `~` must be expanded before writing — scripts read the file and don't expand tilde
- The `vault_path` field is used by all scripts; get it right
- Routing Rules section is read verbatim by `session-summarize.sh` and passed to Claude — plain English descriptions work best
- The `domains` YAML list is metadata only; routing is driven by the `## Routing Rules` section
