---
name: obsidian:ask
description: Ask the Obsidian vault librarian (query or file info). Usage: /obsidian:ask <question or note>
---

Before answering, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ask-staleness.sh"`; if it prints a line, show it to the user as a `⚠` banner above the answer.

Dispatch the `vault-librarian` subagent to handle: $ARGUMENTS

Default to QUERY. If the text asks to store/remember/file/record something, use
INSERT. Relay the subagent's cited answer (QUERY) or write summary (INSERT).
