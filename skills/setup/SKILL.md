---
name: setup
description: Set up the Obsidian plugin for a remote public MCP server or a local vault. Triggers on "/obsidian:setup", "set up obsidian", "configure obsidian plugin", "obsidian first run".
version: 1.0.0
---

# Obsidian Plugin Setup

Interactive first-run wizard. Writes `obsidian.local.md` from user answers so routing works correctly for their vault.

## When to Run

- User invokes `/obsidian:setup`
- `obsidian.local.md` does not exist (first install)
- User says their routing is going to the wrong folder

## Steps

### 0. Choose the Host Role

Choose remote MCP when the user has a shared server and no local vault. Complete
the remote branch below, then STOP this wizard. Do not ask for local vault paths,
create `obsidian.local.md`, install a watcher, or run local keeper commands.
Only follow steps 1 onward for an explicitly local vault setup.

#### Remote MCP setup

1. Obtain the server endpoint and references to separately scoped read/write
   credentials. Never ask the user to paste tokens into chat. Use existing owned
   0400/0600 token files, or the host environment variables
   `OBSIDIAN_MCP_READ_TOKEN` and `OBSIDIAN_MCP_WRITE_TOKEN`.
2. Reuse an installed, verified public client if present. Otherwise install the
   client release from https://github.com/nhangen/obsidian-mcp/releases using its
   public installation instructions and independently verified bootstrap/metadata
   checksums. No llm-tools checkout, plugin-built bundle, client vault mount or
   local server is required. Do not execute an unverified downloaded bootstrap.
3. Preview Claude user-scope registration and exact routine-write permissions:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/setup-mcp.py" \
     --client-dir /absolute/public-client/current \
     --endpoint https://your-server.example/mcp
   ```

   Substitute the actual installed client and endpoint. For token files, add
   `--read-token-file /absolute/read-token --write-token-file /absolute/write-token`.
   Tailnet HTTP additionally requires `--allow-tailnet-http`; do not enable it for
   an arbitrary public HTTP address. After checking the preview, rerun with
   `--apply`. Existing differing registrations or conflicting ask/deny rules are
   refused, never removed or overwritten. Inspect them before proposing a
   migration. The helper supports the normal Claude user configuration; custom
   `CLAUDE_CONFIG_DIR` requires explicit manual host setup. Project and managed
   policy can still override user permissions; verify the effective policy
   during the reconnect check rather than weakening those policies.
4. Reconnect the host, verify discovery and a bounded read. If the user requested
   a save, verify its real note content, INDEX and daily backlink and inspect the
   write receipt. Never call registration itself a successful connection or save.
5. Report automatic capture as UNCHANGED. This setup adds MCP tools, not a new
   session/commit writer. Remote-only users should ask for explicit MCP saves;
   plugin local-vault commands are not remote-compatible merely because the MCP
   tools connected. Do not enable automatic MCP capture, disable legacy hooks,
   uninstall the plugin, replay pending events, or claim full plugin migration
   without the separately verified ownership handoff tracked in #254.

The helper preserves unrelated servers, hooks and permissions, stores credential
references only, defaults to a no-write preview and keeps unique private backups
of changed existing files. A partial setup exits nonzero; inspect the two config
files and backups, then rerun the same arguments to complete it. Backups can
contain existing credentials and must remain private. Do not restore a whole
backup over later unrelated host changes.

#### Explicit capture attachment, separate from connection setup

Only when automatic MCP capture is explicitly requested and a compatible public
client release is installed, check its advertised support first:

```bash
python3 /absolute/public-client/current/bin/obsidian-mcp-native capabilities \
  --release-sha256 <independently-verified-release-json-sha256>
```

Require `claude-plugin` and `attach`, `profile-status`, `drain-status`, `hook`.
Client 0.1.0 lacks this capability; stop without changing ownership if the probe
fails. Use the public release's verified bytes, never copy a private runtime.
Resolve a session folder from the server taxonomy and obtain the declared daily
folder from server setup. Do not infer either from a local vault mount or assume
`Daily` when the server uses another path. Default to one explicitly authorized
user-scope capture profile, not per-workspace enrollment. Require capabilities
`captureScopes["claude-plugin"]` containing `user`; an older client must not be
treated as compatible. Explain that this opt-in captures meaningful sessions in
new workspaces, with no workspace-file scan or upload. Existing project overrides
are retained. Use the authorized session inbox as the default destination:

```bash
python3 /absolute/public-client/current/bin/obsidian-mcp-native attach \
  --host claude-plugin --home /absolute/new-capture-profile \
  --scope user --folder <authorized-session-folder> \
  --daily-folder <declared-server-daily-folder> \
  --release-sha256 <independently-verified-release-json-sha256>
```

The public runtime creates isolated state automatically for new Git and non-Git
workspaces outside their directories. No project registration is needed. User
profiles do not accept `--project` or `--project-mode`. Existing overrides take
precedence; exclusions win over both. Missing configuration must warn without
blocking ordinary work, and must never fall back to a local writer.

Only when a project-specific override is explicitly desired, omit `--scope user`
and supply `--project /absolute/project`. The default project mode is `git` and
requires the exact Git checkout root. For
session capture in a plain directory, require the pinned runtime's capabilities
to advertise `projectModes["claude-plugin"]` containing `directory`, then add
`--project-mode directory` and supply that directory's canonical absolute path.
Do not initialize Git or alter the user's project to satisfy attachment. An older
runtime without this capability must refuse directory setup without changing
ownership. Directory profiles support sessions only, not commit capture. A nested
repository remains session-only unless explicitly attached as a more-specific
Git profile. Never reinterpret an existing immutable profile or its release pin.

Attachment creates capture state only and preserves host/project settings. It
does not activate hooks, change the writer, replay history or reinstall a server.
Stop older plugin sessions and competing writers and inspect pending history
before the separately authorized handoff:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/capture-owner.py" handoff \
  --owner mcp --scope user --profile /absolute/new-capture-profile \
  --verification legacy-writers-stopped-and-history-inspected
```

Use repeatable `--exclude-project /absolute/private-directory` during handoff for
explicit no-capture directories; exclusions cover descendants and are retained
until an explicit `--clear-exclusions`. For a project override instead, use
`--project /absolute/project` and omit `--scope user` at handoff.
Never supply that attestation unless it was actually established. Refused
handoffs preserve evidence and leave admission closed; inspect `status`. Use
`resume` only to cancel the incomplete transition and recover through the same
previous owner, not to bypass pending work. Reconnect the updated plugin and
verify actual Claude hook delivery, session receipts and, for Git profiles,
exact-target commit receipts,
content/INDEX/daily links, replay/conflict and interrupted-write recovery before
claiming migration. Do not disable a public profile as a substitute for draining
it. Source fixtures and scripted hook events do not establish installed-Claude
provider acceptance. Existing Codex projections remain legacy compatibility
unless their public native profile is separately activated and verified.

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

### 6b. Ask for Independent Automation Choices

Ask once, together:

> Enable automatic session capture on this host? (yes/no, default no)
> Enable the vaultkeeper maintenance scheduler on this vault host? (yes/no, default no)

Store the autosave answer as `AUTO_SAVE` and the scheduler answer as
`KEEPER_AUTOSTART`. Map each answer independently: yes → unquoted YAML `true`,
no or an unanswered/default choice → unquoted YAML `false`. Reject other answers
instead of guessing. Keep these answers for the rest of setup; do not ask again
at installation. Neither choice implies the other.

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
- `AUTO_SAVE` → boolean from the autosave answer in Step 6b
- `KEEPER_AUTOSTART` → boolean from the scheduler answer in Step 6b

```
---
vault_path: VAULT_ABSOLUTE_PATH
vault_name: VAULT_FOLDER_NAME
daily_path: DAILY_PATH
auto_save: AUTO_SAVE
keeper_autostart: KEEPER_AUTOSTART
keeper_interval_secs: 900
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

It also records `research_state_change` (`none`, `supports_claim`, `weakens_claim`, `new_claim`, `new_experiment`, `new_evidence`) and `substrate_object`. Use a research destination only when the taxonomy and routing rules define one; validate it with `allowlist_validate`. If none is configured, keep research findings in the ordinary routed project or daily note, preserve the actual `research_state_change`, set `substrate_object: ""`, and choose `project_note` or `daily_only` instead of `substrate_update`. Do not invent a research tree or block ordinary capture because that destination is absent.

## Routing Rules

ROUTING_RULE_LINES
- Keywords "daily, journal, today" → DAILY_PATH
- Ambiguous → INBOX_PATH (with #needs-filing tag)
```

### 8. Explain the Selected Automation

Read back the persisted config before reporting success. Report both choices:

| AUTO_SAVE | KEEPER_AUTOSTART | Result |
|-----------|------------------|--------|
| false | false | Manual session capture; no new scheduler installation. |
| true | false | Automatic session capture; no new scheduler installation. |
| false | true | Manual session capture; install the selected scheduler explicitly using the command below. The autosave hook exits before bootstrap in this combination. |
| true | true | Automatic session capture; the session-end hook can bootstrap the selected scheduler, or use the command below to install it now. |

For a selected scheduler, show this exact manual installation command after the
config has been persisted to its stable location. Run it only on the vault host
if executing the user's selected installation as part of setup; otherwise leave
it for the user and report installation as pending:

```bash
set -euo pipefail
: "${CLAUDE_PLUGIN_ROOT:?plugin root required}"
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh"
CONFIG="$(resolve_obsidian_config "$CLAUDE_PLUGIN_ROOT")" || exit 1
VAULT="$(OBSIDIAN_LOCAL_MD="$CONFIG" obsidian_config_value vault_path)" || exit 1
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 1
SELECTED="$(OBSIDIAN_LOCAL_MD="$CONFIG" obsidian_config_value keeper_autostart)" || exit 1
[ "$SELECTED" = true ] || exit 1
case "$(uname -s)" in
  Darwin)
    : "${HOME:?HOME required for launchd installation}"
    mkdir -p "$HOME/Library/LaunchAgents"
    ;;
esac
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-watcher.sh" install \
  "${CLAUDE_PLUGIN_ROOT}/scripts/vaultkeeper-tick.sh" 900
```

For multiple vault hosts, set `keeper_host_priority` to the same ordered list of
their actual host identifiers in each host's config before activating watchers.
Do not copy another person's machine names. A single vault host needs no sample
priority list.

These explicit choices apply to newly rendered configs only. Do not reinterpret
missing keys in existing configs, disable an installed scheduler, or migrate live
configuration as part of this wizard.

### 9. Confirm

Tell the user:

> Config written to `obsidian.local.md`.
>
> **Vault:** `VAULT_ABSOLUTE_PATH`
> **Domains:** Domain1 → `Projects/Domain1/`, Domain2 → `Projects/Domain2/`, ...
> **Daily notes:** `DAILY_PATH`
> **Fallback (ambiguous):** `INBOX_PATH`
> **Automatic session capture:** `AUTO_SAVE`
> **Maintenance scheduler:** `KEEPER_AUTOSTART` (report installed or pending separately)
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
