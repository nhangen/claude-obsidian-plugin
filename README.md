# obsidian-claude-plugin

Obsidian vault integration for Claude Code. Export conversations, create and retrieve notes, auto-organize by project, and open notes in the Obsidian GUI.

## Features

- **Save conversations** — export Claude sessions to the right project folder automatically
- **Find notes** — search your vault by keyword, tag, or topic
- **Create notes** — new notes or full project folder structures
- **Daily note** — append to or read today's daily note
- **Reorganize** — deep vault analysis with a dedicated subagent
- **Session-end hook** — auto-saves significant sessions silently on close
- **Obsidian URI integration** — opens notes directly in the GUI after writing

## Skills (natural language)

| Trigger | Action |
|---|---|
| "save this to Obsidian" | Summarizes and routes session to correct project folder |
| "find my notes on X" | Searches vault, returns ranked results |
| "create a note about X" | Creates note or project folder structure |
| "add to my daily note" | Appends to `Daily/YYYY-MM-DD.md` |
| "reorganize my vault" | Launches vault-organizer subagent |

## Commands

| Command | Usage |
|---|---|
| `/obsidian:save [topic]` | Save current session |
| `/obsidian:find <query>` | Search vault |
| `/obsidian:new <title>` | Create note or project |
| `/obsidian:daily` | Open/append today's daily note |
| `/obsidian:bookmark` | Drop a chapter marker in the session |

## Installation

```bash
claude plugin marketplace add <your-github-username>/obsidian-claude-plugin
claude plugin install obsidian@<your-github-username>
```

Then create your local config:

```bash
cp obsidian.local.md.example obsidian.local.md
# edit obsidian.local.md with your vault path and settings
```

## Config

Copy `obsidian.local.md.example` to `obsidian.local.md` (gitignored) and set:

```yaml
vault_path: /path/to/your/vault
vault_name: Obsidian
auto_save: true
auto_open: true
time_gap_minutes: 30
```

`obsidian.local.md` is machine-specific and never committed.

## Vault structure expected

```
vault/
├── Projects/
│   ├── Development/
│   ├── Physics-AI-ML/
│   └── ...
├── Daily/
├── Inbox/
└── Reference/
```

Sessions are routed by domain keyword detection. Ambiguous content falls back to `Inbox/`.
