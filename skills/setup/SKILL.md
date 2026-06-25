---
name: setup
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

Resolve any existing config (checks the stable path and legacy locations):

```bash
EXISTING="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"
```

If `$EXISTING` is non-empty, tell the user (show the resolved path):

> Config already exists at `$EXISTING`. Running setup will overwrite it. Continue? (yes/no)

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

### 4b. Ask for Precedence (optional)

Ask:

> If multiple domains' keywords could match the same note, which wins?
> Provide a precedence integer per domain (lower number wins). Skip with Enter to leave precedence blank — the plugin will prompt at save-time on multi-matches.
>
> **Domain1:** (number, e.g. 10)
> **Domain2:** (number, e.g. 20)
>
> Example: Development=10, Work=20, Personal=30 means a note matching both Development and Work routes to Development.

Collect optional precedence per domain. If the user skips all, omit the `Precedence` column from the generated taxonomy table.

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

Build the config file by replacing each ALL_CAPS placeholder below with the user's actual values, then write it to the **stable, version-independent** location so plugin updates never strand it:

```bash
DEST="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh" --stable)"
mkdir -p "$(dirname "$DEST")"
# write the rendered config to "$DEST"
```

`$DEST` resolves to `${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`. Do not write into the plugin cache dir — that copy disappears on every update.

Replace:
- `VAULT_ABSOLUTE_PATH` → expanded absolute path from Step 2
- `VAULT_FOLDER_NAME` → last path component of the vault path (e.g. `Obsidian`)
- `DOMAIN_LIST` → one `  - DomainName` line per domain
- `TAXONOMY_HEADER` → `| Domain | Vault path | Precedence | Notes |` if any precedence values were provided in Step 4b; otherwise `| Domain | Vault path | Notes |`.
- `TAXONOMY_SEPARATOR` → matching separator row: `|--------|-----------|------------|-------|` (4-col) or `|--------|-----------|-------|` (3-col).
- `TAXONOMY_ROWS` → one row per domain in the same shape as the header. **Substitute the actual domain name in both columns.** With precedence: `| <DomainName> | Projects/<DomainName>/ | <prec-or-blank> | |`. Without: `| <DomainName> | Projects/<DomainName>/ | |`. Replace each `<DomainName>` with the user's domain (e.g. `Development`, producing `| Development | Projects/Development/ | 10 | |`). Pick one shape for the whole table — do not mix.
- `DAILY_AND_INBOX_ROWS` → emit `| Daily | DAILY_PATH | 50 | |` and `| Inbox | INBOX_PATH | 99 | Fallback for ambiguous notes |` if precedence column is included; otherwise `| Daily | DAILY_PATH | |` and `| Inbox | INBOX_PATH | Fallback for ambiguous notes |`. Substitute `DAILY_PATH` and `INBOX_PATH` with the values collected in Steps 5 and 6.
- `ROUTING_RULE_LINES` → one routing line per domain: `- Keywords "kw1, kw2" → Projects/DomainName/`
- `DAILY_PATH` → value from Step 5
- `INBOX_PATH` → value from Step 6

```
---
vault_path: VAULT_ABSOLUTE_PATH
vault_name: VAULT_FOLDER_NAME
daily_path: DAILY_PATH
auto_save: true
auto_open: false
time_gap_minutes: 30
smart_detect: true
strict_domains: true
dedup_jaccard_threshold: 0.4
moc_promotion: true
moc_promotion_threshold: 3
intent_high_score: 0.70
intent_margin: 0.15
capture_high_score: 0.70
domains:
DOMAIN_LIST
---

# Obsidian Plugin Config

Vault is at `VAULT_ABSOLUTE_PATH`.

## Project Taxonomy

TAXONOMY_HEADER
TAXONOMY_SEPARATOR
TAXONOMY_ROWS
DAILY_AND_INBOX_ROWS

The `Vault path` column above is the canonical allow-list of top-level folders. Skills refuse to write outside this list while `strict_domains: true`.

If a `Precedence` column is present, lower number wins when keywords from multiple domains match the same note. If it is absent, the skill prompts the user to pick on multi-match.

## Session Intent Inference

Session capture infers `session_intent` (`execution`, `research`, `planning`, `reflection`, `operations`, `scratch`) separately from `capture_action` (`none`, `daily_only`, `project_note`, `substrate_update`, `decision_record`). The confidence thresholds in frontmatter control when the inference is treated as high confidence.

It also records `research_state_change` (`none`, `supports_claim`, `weakens_claim`, `new_claim`, `new_experiment`, `new_evidence`) and `substrate_object`. For research-adjacent sessions, agents should ask whether the session created, weakened, supported, or tested a research claim. When it did, create or update one small object under `Projects/Physics-AI-ML/Research-Substrate/` and link it from the session note.

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
- `strict_domains: true` (default) makes `## Project Taxonomy`'s `Vault path` column the canonical allow-list. Skills refuse to write to top-level folders that are not on the list, preventing silent alias folders. To add a new top-level folder, add a Project Taxonomy row (or rerun `/obsidian:setup`) — never let routine saves create new folders.
- `intent_high_score: 0.70`, `intent_margin: 0.15`, and `capture_high_score: 0.70` tune session-intent and capture-action confidence scoring.
