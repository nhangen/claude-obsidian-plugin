---
name: daily-note
description: Reads, creates, or appends to the Obsidian daily note. Triggers on phrases like "add to my daily note", "update today's note", "what's in my daily note", "open today's note", "daily note", "log this to today".
version: 1.1.0
---

# Daily Note Management

Manages the daily note in `Daily/YYYY-MM-DD.md`.

Append and create-on-absent are filed through the **keeper-save** skill
(`op: append`) — the vault-librarian owns target resolution, creating from the
daily template when the file is absent, and the append itself. The read path
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

keeper-save → the librarian resolves `Daily/<date>.md`, creates it from
`Daily/_Daily Template.md` if absent, and appends the section. Relay the path it
returns. To log to a non-today date, pass that `date` (or a `target` path)
instead.
