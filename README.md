# obsidian

**Obsidian vault integration for Claude Code — auto-save sessions, capture git commit context, and create/recall notes from the CLI.**

## Why

Long Claude sessions and the commits they produce hold context that's gone the moment the session ends: why a decision was made, what was investigated and rejected, loose ends flagged for later. Pasting that into Obsidian by hand is the kind of chore that doesn't get done. This plugin captures it automatically — sessions on stop, commit context on every `git commit` — and routes notes to the right folder by domain.

## How it works

- A **Stop hook** runs at session end; if the session is significant, a background `claude --print` summarizer writes a structured note to your vault.
- Session capture infers both `session_intent` and `capture_action` with confidence scores and evidence bullets, so routing can distinguish execution, research, planning, operations, reflection, and scratch work.
- A **PostToolUse hook** on `Bash` detects successful `git commit` calls and appends goal / investigation / decision / loose-ends bullets to a per-repo daily file.
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

## Hooks

| Event | Script | Behavior |
|---|---|---|
| `Stop` | `scripts/session-save.sh` | Auto-saves significant sessions via background `claude --print` summarizer. Skips trivial sessions. |
| `PostToolUse` (Bash) | `scripts/commit-capture.sh` | After a successful `git commit`, appends a context block to `<vault>/Projects/Development/<org>_<repo>/<YYYY-MM-DD>.md`. Per-repo overrides supported (e.g. `altamira2/mtf-builder` → flat `<vault>/Altamira/<date>-mtf-builder-commits.md`). |

The PostToolUse hook is gated — it inspects the Bash command first and exits silently for non-commit calls, so it doesn't interrupt normal tool flow.

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
Captured a1b2c3d → awesomemotive_optin-monster-app/2026-05-12.md
```

## Install

```bash
claude plugin install nhangen/obsidian
/obsidian:setup
```

The setup wizard prompts for vault path, domain names, keywords per domain, and daily/inbox paths, then writes `obsidian.local.md` to the plugin root.

## Configuration

`obsidian.local.md` is machine-specific and gitignored. Generate it with `/obsidian:setup`, or copy the example:

```bash
cp obsidian.local.md.example obsidian.local.md
```

Key frontmatter fields:

```yaml
vault_path: /absolute/path/to/your/vault
vault_name: Obsidian          # must match the vault name in the Obsidian app
daily_path: Daily/            # relative to vault root
auto_save: true               # disable session autosave
auto_open: true               # open note in GUI after writing
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

Per-repo commit-capture overrides go in the same file under a `## Commit Capture Overrides` section.

## Architecture

```
.claude-plugin/plugin.json    Plugin manifest
commands/*.md                 Slash command entry points
skills/obsidian/*/SKILL.md    Skill logic (save, find, recall, setup, …)
hooks/hooks.json              Stop + PostToolUse hook registration
scripts/                      Hook executables (commit-capture, session-save, …)
agents/                       Subagents (vault-organizer for /obsidian reorganize paths)
integrations/                 External tool integrations
obsidian.local.md             User config (gitignored)
```

The plugin root is resolved by Claude Code via `${CLAUDE_PLUGIN_ROOT}` — scripts never hardcode a version path.

## Known Limitations

- The Stop hook requires `claude` on `PATH` for background summarization. If absent, the session save no-ops with a logged warning.
- Commit capture relies on parsing `git` output; very large commits are truncated to keep the note readable.
- Routing is keyword-based, not semantic. Intent inference records confidence and evidence, but folder placement still depends on taxonomy/routing rules; ambiguous sessions can still land in `Inbox/`.

## License

MIT
