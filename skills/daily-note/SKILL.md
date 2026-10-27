---
name: daily-note
description: Reads, creates, or appends to the Obsidian daily note. Triggers on phrases like "add to my daily note", "update today's note", "what's in my daily note", "open today's note", "daily note", "log this to today".
version: 1.2.0
---

# Daily Note Management

Run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/capture-owner.py" status` first.
For stable MCP ownership, use bounded MCP daily-note reads and
`obsidian:keeper-save`'s MCP APPEND branch for writes. The server's configured
daily path is authoritative; do not assume a local `Daily/` directory, render a
local template, or invoke GUI open. STOP before the local procedure. For
disabled/draining ownership or an error, do not start a write or switch routes.

Manages the daily note in `Daily/YYYY-MM-DD.md`.

Append and create-on-absent are filed through the **keeper-save** skill
(`op: append`) — a single direct `keeper append` call (no subagent) that
resolves `Daily/<date>.md`, creates it from the daily template when absent, and
appends. The read path
stays native (it only reads).

## Vault Path (read path only)

```bash
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"
VAULT_PATH=$(grep '^vault_path:' "$CONFIG" | sed 's/vault_path: //')
```

If the resolver prints nothing, tell the user to run `/obsidian:setup` and stop.

## Steps

### Read today's note:
1. Determine today's date: `date +%Y-%m-%d`.
2. `cat "$VAULT_PATH/Daily/$(date +%Y-%m-%d).md"` — if it exists, return contents.
3. If not, offer to create it (creation goes through the append path below).

### Append to today's note (and create-on-absent):
Invoke the `obsidian:keeper-save` skill with an append payload:
- `op` — `append`
- `date` — today's date (`date +%Y-%m-%d`)
- `section` — `## HH:MM — [Topic]` (current time + the topic)
- `body` — the content to log

keeper-save runs `keeper append` directly: it resolves `Daily/<date>.md`,
creates it from `Daily/_Daily Template.md` if absent, and appends the section.
Do not dispatch the vault-librarian for this. Relay the path it
returns. To log to a non-today date, pass that `date` (or a `target` path)
instead.
