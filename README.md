# obsidian

**Obsidian vault integration for Claude Code and Codex — auto-save Claude sessions, capture git commit context, and create/recall notes from the CLI.**

## Why

Long agent sessions and the commits they produce hold context that's gone the moment the session ends: why a decision was made, what was investigated and rejected, loose ends flagged for later. Pasting that into Obsidian by hand is the kind of chore that doesn't get done. This plugin captures Claude Code sessions on stop, captures commit context automatically in Claude Code and through an installed post-commit skill in Codex, and routes notes to the right folder by domain.

## How it works

- A **Stop hook** runs at session end; if the session is significant, a background `claude --print` summarizer writes a structured note to your vault.
- Session capture infers `session_intent`, `capture_action`, and `research_state_change` with confidence scores and evidence bullets, so routing can distinguish execution, research, planning, operations, reflection, scratch work, and claim/evidence changes that should land in the Research Substrate.
- In Claude Code, a **PreToolUse/PostToolUse hook pair** on `Bash` notices when a `git commit` actually moved `HEAD` and appends goal / investigation / decision / loose-ends bullets to a per-repo daily file.
- In Codex, the installed **`commit-capture` skill** runs after a successful commit, obtains the same sanitized record through `commit-meta.sh`, and appends through the same keeper primitive. Current Codex CLI sessions do not deliver this plugin's bundled hooks, so the skill is instruction-driven rather than hook-driven.
- **Slash commands** (skills) cover the manual paths: save, find, recall, daily, new, bookmark, setup.
- **Routing** is driven by `obsidian.local.md` — a vault path and a keyword-based domain taxonomy you edit directly.

## Skills

| Command | Purpose |
|---|---|
| `/obsidian:setup` | First-run wizard. Writes `obsidian.local.md` with vault path, domains, routing. |
| `/obsidian:save [topic]` | Save the current session. Optional topic hint overrides auto-routing. |
| `/obsidian:find <query>` | Search the vault by keyword, tag, or topic. |
| `/obsidian:new <title>` | Create a new note or project folder. |
| `/obsidian:daily [content]` | Open or append to today's daily note. |
| `/obsidian:bookmark [label]` | Mark a chapter boundary; saved as a separate note at session end. |
| `/obsidian:recall <query>` | Cross-search vault, git history, GitHub PRs, and claude-mem. |
| `/obsidian:ask` | Ask the vault librarian — index-grounded answers with citations, or file new info without back-and-forth. |
| _(trigger-only, no slash command)_ | `reorganize` — analyzes and reorganizes the vault or a project folder via the `vault-organizer` subagent; proposes a plan and waits for approval before moving anything. Triggers on phrases like "reorganize my vault", "clean up obsidian". |

### Vault Librarian

`/obsidian:ask` dispatches the `vault-librarian` subagent. It answers queries by
routing to the relevant domain folder, refreshing that slice's `INDEX.md`
on-demand (two-stage: file mtime narrows candidates, a stored `size:sha256`
content hash confirms real changes — so a Syncthing mtime-bump doesn't trigger
re-indexing), then reading only the indexed notes and citing them with a
confidence level. It reports indexing gaps rather than answering from a partial
slice, and falls back to the `find` skill for raw-text search when the index
misses.

For inserts it routes new notes through the taxonomy, dedups against existing
notes, writes via the matching `Templates/` file, and appends a link to the
right INDEX — deferring genuine unknowns to `[ask]` markers in `Pending.md`
instead of interrupting you.

Per-INDEX machine state (content hashes + last-reconciled timestamp) lives in a
hidden `.<index>.state` sidecar file beside each `INDEX.md`, so the human-
readable index is only ever appended to, never rewritten.

### keeper-save (agent-facing write)

`keeper-save` is the structured write entry point for **agents and sub-skills**.
Humans use `/obsidian:ask`; agents that need to persist a note programmatically
use this skill instead.

Payload format — a temp file with header lines then a `---` separator:

```
title: <required>
folder_hint: <optional — target folder path>
type: <optional — finding, decision, observation, …>
links: <optional — comma-separated wikilink targets>
---
<body — required>
```

The skill validates the payload (title + body required), then dispatches the
`vault-librarian` INSERT with the structured fields. Routing, dedup, and template
selection are owned by the librarian — a keeper-saved note is identical to a
librarian-filed one.

**Opt-in by design.** Calling `keeper-save` routes through the librarian.
Not calling it bypasses the librarian entirely. `create-note`, `daily-note`,
and `save-conversation` have been migrated to route their writes through
`keeper-save` (v1.11.0–1.13.0); any other writer not yet migrated is unchanged
until it opts in.

## vaultkeeper watcher

The plugin includes a two-layer background maintenance system that keeps the vault accurate without LLM overhead on every tick.

### Two-layer model

**Layer 1 — deterministic substrate tick** (`scripts/vaultkeeper-tick.sh`): a pure-bash script that runs on cron (Linux) or launchd (macOS), namespaced `com.nhangen.obsidian-vaultkeeper`. It validates frontmatter against the required keys, scans for unfiled notes, open `[ask]` markers, and promotable clusters, then surfaces candidates into `Librarian.md` and appends only genuinely-new items to `Pending.md`. No LLM involved; no writes to the CEO vault.

**Layer 2 — on-demand agent** (`/obsidian:ask`): the `vault-librarian` subagent answers queries and acts on the pre-computed candidate lists from Layer 1, only spinning up an LLM when a human query needs it.

### Machine-owned Librarian.md

`Librarian.md` is written exclusively by the keeper tick. Manual edits do not persist — the next tick overwrites it atomically. Read it as a live dashboard; don't edit it.

### Activation (automatic)

The keeper activates itself. The first time the session-end hook (`session-save.sh`) runs on a host where the keeper isn't scheduled yet, it seeds the frontmatter schema, writes default keeper config, and installs the namespaced scheduler — no command to run. Once installed it's a cheap no-op on every later session end.

Because Syncthing carries the vault but not a launchd plist / crontab line, each host self-activates the first time you work on it. Opt out with `keeper_autostart: false` in `obsidian.local.md`.

To install manually (or on a host you never run a session on), the engine is still directly invokable:

```bash
bash scripts/install-watcher.sh install "$(pwd)/scripts/vaultkeeper-tick.sh"
```

Either way the keeper registers under the `com.nhangen.obsidian-vaultkeeper` namespace — visible in `crontab -l` (Linux) or `launchctl list | grep obsidian-vaultkeeper` (macOS) for audits.

### No CEO writes

The keeper writes only to the Obsidian vault (`vault_path` from `obsidian.local.md`). It never writes to the CEO vault or any other synced store.

## Hooks

| Event | Script | Behavior |
|---|---|---|
| `SessionStart` | `scripts/config-doctor.sh` | If the plugin is installed but unconfigured on this host (no `obsidian.local.md`) while a synced vault is detectable, surfaces an advisory so the agent can offer `/obsidian:setup`. Silent once configured, and silent on hosts with no vault. Advisory only — a hook can't prompt. |
| `Stop` | `scripts/session-save.sh` | Auto-saves significant sessions via background `claude --print` summarizer. Skips trivial sessions. |
| `PreToolUse` (Bash) | `scripts/commit-capture-pre.sh` | For a Bash call that is about to run `git commit`, records the target repo's current `HEAD` (and the repo the command named, which may not exist yet). Writes nothing else, and always exits 0 — a PreToolUse hook that fails would block the command. |
| `PostToolUse` (Bash) | `scripts/commit-capture.sh` | If `HEAD` moved during the call and git says the move was a commit of ours, emits the sanitized commit record that the matching skill appends to the routed vault note. |

Both hooks are gated — they inspect the Bash command first and exit silently for non-commit calls, so they don't interrupt normal tool flow.

**The two halves are one mechanism: register both or neither.** Whether a commit landed is decided by comparing `HEAD` before the call against `HEAD` after — the only signal that distinguishes a commit from a `git commit` that was rejected, aborted, short-circuited by `false &&`, or had nothing to commit. A tip that moved is necessary but not sufficient, so the post-hook also asks git *what* the move was: the old tip (or its parent, for an amend) has to be reachable from the new one, and the new commit's committer has to be you — a `git pull` that fast-forwards in front of a failed commit leaves someone else's commit at the tip.

With only the PostToolUse half wired up there is no "before". The hook says so, alongside every other reason a commit went uncaptured. Everything it says — the record and every diagnostic — is delivered as `hookSpecificOutput.additionalContext`, which is the only channel a PostToolUse hook has on exit 0: bare stdout goes to the debug log rather than the transcript. Only a line beginning `obsidian-commit-capture: hash=` is a record.

## Examples

```
/obsidian:setup
/obsidian:save hubspot v3 migration
/obsidian:find "tax reverse charge"
/obsidian:recall "what did we decide about the refresh token race?"
/obsidian:daily Pushed PR #6955, waiting on review
```

After a `git commit`:

```
Captured a1b2c3d → Awesome Motive/sessions/2026-05-12-optin-monster-app.md
```

## Install

```bash
claude plugin install nhangen/obsidian
/obsidian:setup
```

The setup wizard prompts for vault path, domain names, keywords per domain, and daily/inbox paths, then writes `obsidian.local.md` to the stable config location (see below).

For Codex commit capture:

```bash
codex plugin marketplace add nhangen/claude-obsidian-plugin
codex plugin add obsidian@nhangen-codex-plugins
```

Start a new session and configure `vault_path` in the stable config file described below. The Codex package exposes only the post-commit capture skill; it does not load the Claude session-end watcher, hooks, or other Claude-specific skills. See `integrations/codex/commit-capture.md` for the runtime contract.

## Configuration

`obsidian.local.md` is machine-specific and gitignored. It is resolved in a **version-independent** way so plugin updates never strand it — readers check, in order:

1. `$OBSIDIAN_LOCAL_MD` (explicit override)
2. `${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md` — **the canonical home; setup writes here**
3. `${CLAUDE_PLUGIN_ROOT}/obsidian.local.md` (legacy fallback for older installs)

`scripts/lib/resolve-config.sh` implements this; run it directly to print the resolved path (`--stable` prints the canonical location). Generate the config with `/obsidian:setup`, or copy the example to the stable path:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian"
cp obsidian.local.md.example "${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md"
```

Key frontmatter fields:

```yaml
vault_path: /absolute/path/to/your/vault
vault_name: Obsidian          # must match the vault name in the Obsidian app
daily_path: Daily/            # relative to vault root
auto_save: true               # disable session autosave
auto_open: false              # open note in GUI after writing (opt-in)
strict_domains: true          # refuse to create folders outside the taxonomy
moc_promotion: true           # promote recurring topics to Maps of Content
intent_high_score: 0.70       # high-confidence intent/action threshold
intent_margin: 0.15           # required margin over the next plausible intent/action
capture_high_score: 0.70      # high-confidence durable-capture threshold
```

The body of `obsidian.local.md` defines two things the skills read directly:

- **`## Project Taxonomy`** — table mapping each domain to a vault path. This is the canonical allow-list; with `strict_domains: true`, saves to any other top-level folder are refused.
- **`## Routing Rules`** — plain-English keyword lists that decide which domain a session or note belongs to. Ambiguous content falls back to `Inbox/` with a `#needs-filing` tag.
- **Session intent inference** — capture now records `session_intent`, `capture_action`, confidence scores, and evidence bullets. Folder routing still uses the taxonomy; intent decides whether the session is execution, research, planning, reflection, operations, or scratch, and whether it warrants no capture, daily-only capture, a project note, a research-substrate update, or a decision record.
- **Research substrate contract** — capture also records `research_state_change` and `substrate_object`. Agents should use this to create or update one small object under `Projects/Physics-AI-ML/Research-Substrate/` whenever a session creates, weakens, supports, or tests a research claim.

Per-repo commit-capture overrides go in the same file under a `## Commit Capture Overrides` section.

## Architecture

```
.claude-plugin/plugin.json    Plugin manifest
commands/*.md                 Slash command entry points
skills/*/SKILL.md             Skill logic (save, find, recall, setup, …)
hooks/hooks.json              Stop + Pre/PostToolUse hook registration
packages/codex/               Self-contained Codex package with only manual commit capture
scripts/                      Hook executables (commit-capture, session-save, …)
scripts/lib/commit-capture-parse.sh Payload decoding + repo resolution shared by the commit-capture hook pair
scripts/lib/resolve-config.sh Version-independent config-path resolver
scripts/lib/allowlist-validate.sh Frontmatter/path allowlist validation shared by writers
scripts/lib/dedup-scan.sh     Shared dedup-against-existing-notes scan
scripts/lib/keeper-save-payload.sh Payload parsing/validation for keeper-save
scripts/lib/vault-index.sh    Shared INDEX.md read/refresh helpers
scripts/lib/moc-promote.sh    Retargets inbound wikilinks when an MOC promotion moves notes
scripts/keeper                CLI entry point for keeper insert/append operations
scripts/commit-meta.sh        Emits one capture record for an existing commit, for harnesses with no hook
agents/                       Subagents (vault-organizer for /obsidian reorganize paths)
integrations/                 Cursor fallback and Codex manual commit-capture documentation
obsidian.local.md.example     Config template (real config lives at the stable path, gitignored)
```

Claude Code supplies `${CLAUDE_PLUGIN_ROOT}`. The Codex skill resolves its bundled helpers relative to its installed `SKILL.md`; neither integration searches versioned cache paths. User config is resolved separately by `scripts/lib/resolve-config.sh` (stable path first, plugin root as legacy fallback), so updating the plugin never strands the config.

## Known Limitations

- The Stop hook requires `claude` on `PATH` for background summarization. If absent, the session save no-ops with a logged warning.
- Commit capture asks `git` about a HEAD snapshot taken before the call, so a failed or dry-run commit is not captured. A call that makes more than `OBSIDIAN_COMMIT_MAX_RECORDS` commits (20 by default) captures the oldest of them and names the shas it skipped rather than truncating silently. The append is idempotent per commit sha, read from the note itself, so a re-run or a second host does not duplicate a record.
- Routing is keyword-based, not semantic. Intent inference records confidence and evidence, but folder placement still depends on taxonomy/routing rules; ambiguous sessions can still land in `Inbox/`.

## License

MIT
