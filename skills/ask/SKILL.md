---
name: ask
description: Ask the Obsidian vault librarian a question or file new information into the vault. Triggers on "ask my vault", "what do we know about X", "where in my vault is Y", "what did I decide about Z", "remember this in obsidian", "file this note". Dispatches the vault-librarian subagent for index-grounded answers and no-back-and-forth inserts.
version: 1.1.0
---

# Ask the Vault Librarian

Run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/capture-owner.py" status` first.
For stable MCP ownership, QUERY uses bounded public MCP reads or the retained
read-only `ask_vault_librarian` prompt. INSERT resolves routing/dedup with those
reads and invokes `obsidian:keeper-save`'s MCP branch. Do not dispatch a local
librarian writer, read a client-side vault, or fall back on transport failure.
STOP before the local procedure below. Disabled/draining ownership or an error
must not start a write; report the state.

Dispatch the `vault-librarian` subagent to answer a vault query or file new
information.

## When to use which operation

- **QUERY** (default): the request asks for knowledge — "what do we know…",
  "where is…", "what did I decide…", "summarize what's in <domain>".
- **INSERT**: the request asks to store something — "remember…", "file this…",
  "record this decision…", "add a note about…".

**Already-resolved writes skip this skill.** If the caller already has the
body and the exact target (append or resolved insert), use `obsidian:keeper-save`
instead — it is one local keeper call with no subagent. Dispatch the librarian
here only for a query, or an INSERT whose routing/dedup is unresolved.

## Steps

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ask-staleness.sh"`; if it prints a
   line, show it to the user as a `⚠` banner before the answer.
2. Dispatch the `vault-librarian` agent with the user's request verbatim and an
   explicit operation hint (`QUERY` or `INSERT`).
3. Relay the subagent's result to the user: for QUERY, the cited answer +
   confidence; for INSERT, what was written and where.
4. If the subagent reports low-confidence routing or a near-duplicate, surface
   its question to the user — do not auto-resolve it.

**MCP QUERY is read-only.** Legacy QUERY may reconcile INDEX links through the
ownership-guarded `scripts/vault-index-apply` CLI, but does not modify note
content. The raw library is an internal server/maintenance primitive, not a
client write entry point. Routes to `recall` or claude-mem as typed by the question.
