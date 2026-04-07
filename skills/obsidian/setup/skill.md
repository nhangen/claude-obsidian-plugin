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
- First, expand any leading `~` to the user's full home directory path (e.g. `~/Documents/Obsidian` → `/Users/yourname/Documents/Obsidian`). Use the expanded path for all remaining steps.
- Check the directory exists using the Bash tool: `test -d "/expanded/path" && echo exists || echo missing`
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
>
> Note: avoid spaces in domain names (use hyphens instead, e.g. `Client-Work` not `Client Work`) — shell scripts generate folder paths from these names.

Parse the comma-separated list into a clean array (trim whitespace).

### 4. Ask for Keywords per Domain

For each domain, ask in a single message listing all domains at once:

> For each domain below, provide comma-separated keywords that should route notes there.
>
> **Domain1:** (keywords)
> **Domain2:** (keywords)
>
> Example: Development → `code, git, bug, deploy, api, claude, plugin`

Collect the keyword list for each domain from the user's reply.

### 5. Ask for Daily Notes Path

Ask:

> Where are your daily notes? (relative to vault root)
> Default: `Daily/` — press Enter to accept, or type a custom path.

Store this as DAILY_PATH (default `Daily/`).

### 6. Ask for Inbox Path

Ask:

> Where should ambiguous notes go? (relative to vault root)
> Default: `Inbox/` — press Enter to accept.

Store this as INBOX_PATH (default `Inbox/`).

### 7. Write obsidian.local.md

Build the config file by replacing each ALL_CAPS placeholder below with the user's actual values, then write it to `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md`.

Replace:
- `VAULT_ABSOLUTE_PATH` → expanded absolute path from Step 2
- `VAULT_FOLDER_NAME` → last path component of the vault path (e.g. `Obsidian`)
- `DOMAIN_LIST` → one `  - DomainName` line per domain
- `TAXONOMY_ROWS` → one table row per domain: `| DomainName | Projects/DomainName/ | |`
- `ROUTING_RULE_LINES` → one routing line per domain: `- Keywords "kw1, kw2" → Projects/DomainName/`
- `DAILY_PATH` → value from Step 5
- `INBOX_PATH` → value from Step 6

```
---
vault_path: VAULT_ABSOLUTE_PATH
vault_name: VAULT_FOLDER_NAME
daily_path: DAILY_PATH
auto_save: true
auto_open: true
time_gap_minutes: 30
smart_detect: true
domains:
DOMAIN_LIST
---

# Obsidian Plugin Config

Vault is at `VAULT_ABSOLUTE_PATH`.

## Project Taxonomy

| Domain | Vault path | Notes |
|--------|-----------|-------|
TAXONOMY_ROWS
| Daily | DAILY_PATH | |

## Routing Rules

ROUTING_RULE_LINES
- Keywords "daily, journal, today" → DAILY_PATH
- Ambiguous → INBOX_PATH (with #needs-filing tag)
```

### 8. Confirm

Tell the user:

> Config written to `obsidian.local.md`.
>
> **Vault:** `VAULT_ABSOLUTE_PATH`
> **Domains:** Domain1 → `Projects/Domain1/`, Domain2 → `Projects/Domain2/`, ...
> **Daily notes:** `DAILY_PATH`
> **Fallback (ambiguous):** `INBOX_PATH`
>
> GUI open (`auto_open`) works on macOS and Windows. On Windows/WSL, Obsidian must be running.
>
> To change any of this, edit `obsidian.local.md` directly or re-run `/obsidian:setup`.

## Notes

- Vault path must be written as an absolute path — shell scripts do not expand `~`
- The `vault_path` and `daily_path` fields are read by shell scripts; get them right
- `vault_name` is read by `open-in-obsidian.sh` to construct the Obsidian URI — it must match the vault name shown in the Obsidian app's vault switcher
- Routing Rules section is read verbatim by `session-summarize.sh` and passed to Claude — plain English descriptions work best
- The `domains` YAML list is metadata only; routing is driven by the `## Routing Rules` section
