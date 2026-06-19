---
name: ask
description: Ask the Obsidian vault librarian a question or file new information into the vault. Triggers on "ask my vault", "what do we know about X", "where in my vault is Y", "what did I decide about Z", "remember this in obsidian", "file this note". Dispatches the vault-librarian subagent for index-grounded answers and no-back-and-forth inserts.
version: 1.0.0
---

# Ask the Vault Librarian

Dispatch the `vault-librarian` subagent to answer a vault query or file new
information.

## When to use which operation

- **QUERY** (default): the request asks for knowledge — "what do we know…",
  "where is…", "what did I decide…", "summarize what's in <domain>".
- **INSERT**: the request asks to store something — "remember…", "file this…",
  "record this decision…", "add a note about…".

## Steps

1. Dispatch the `vault-librarian` agent with the user's request verbatim and an
   explicit operation hint (`QUERY` or `INSERT`).
2. Relay the subagent's result to the user: for QUERY, the cited answer +
   confidence; for INSERT, what was written and where.
3. If the subagent reports low-confidence routing or a near-duplicate, surface
   its question to the user — do not auto-resolve it.
