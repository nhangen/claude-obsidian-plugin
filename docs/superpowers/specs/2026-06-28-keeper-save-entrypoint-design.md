# Keeper-Save — agent-facing write entry point (design spec)

**Date:** 2026-06-28
**Status:** Approved by user — proceed to plan + build (do not push without approval).
**Supersedes the framing in:** `~/ML-AI/claude/docs/superpowers/specs/2026-06-27-vaultkeeper-design.md`

## Premise (settled over discussion)

The vaultkeeper is already built, shipped (v1.9.4), and running. Its write path — route, dedup, template, INDEX-link, return where-filed — exists as the `vault-librarian` INSERT flow, reachable by humans via `/obsidian:ask`. Cross-host safety (election + quarantine) and surfacing are done.

The goal is **not** to rebuild any of that, and **not** an enforced gate. It is to let **any agent invoke the keeper to save**, while anything that doesn't call it simply **bypasses** and writes as it does today. Calling the entry point *is* the opt-in; not calling it *is* the bypass. No flags, no shadow modes, no per-writer switches. Adoption is gradual and non-disruptive by construction.

This is an **opt-in helper, not a mandatory pre-commit gate.** A direct writer genuinely bypasses; the keeper can't stop a write it was never called for. That is acceptable and likely the right permanent shape — a vault that humans edit in Obsidian and syncthing mutates cannot be hard-gated. (True enforcement would be a later, separate PreToolUse-hook decision; out of scope.)

## The one missing piece

`/obsidian:ask` INSERT takes the *user's natural-language* request. There is no clean **agent-facing** contract: a structured payload another agent (Hari first, then others) hands in to get a deterministic, keeper-committed file.

## Design

1. **A `keeper-save` skill** — the agent-facing door. Input is a structured payload:
   ```
   { title, body, folder_hint?, links?[], type? }
   ```
   It dispatches the existing `vault-librarian` INSERT with that payload and returns the committed note path (or the librarian's low-confidence/duplicate question, surfaced not auto-resolved).
2. **Shared filing rules.** The skill must produce a note **identical** to the librarian's existing INSERT output (same routing via `## Project Taxonomy`/`## Routing Rules`, same template, same INDEX link). It reuses the librarian's path — it does not re-implement routing — so a writer that switches to it sees no behavior change.
3. **Bypass is the default.** Every existing writer keeps its current direct-write behavior until it is individually repointed at `keeper-save`. Nothing changes on install.
4. **Payload validation** is a small deterministic helper (testable per the repo's bash-test convention): reject a payload missing `title` or `body`; normalize `links`; pass `folder_hint`/`type` through. Malformed payload → clear error, no partial write.

## Migration order (gradual, one at a time — NOT in this build)

The writers that will move onto `keeper-save` over time, lowest-risk first:
`create-note` → `daily-note` → `save-conversation` → `commit-capture` → Hari publish → out-of-plugin (overnight, weekly-synthesis, CEO reports).

**This build delivers the entry point + its contract + tests only.** It migrates **zero** writers (so nothing is disrupted). The first real adopter (likely Hari or `create-note`) is a separate, later change once the door is proven.

## Out of scope
- Migrating any existing writer (separate, gradual).
- Enforcement / blocking direct writes (a later hook decision; conflicts with human+sync writes).
- Any change to election, quarantine, surfacing, or the watcher.

## Testing (revert-fails)
- Payload validation: missing `title` or `body` → non-zero + message; valid payload → passes; `links` normalized. Each assertion fails if the validation logic is reverted.
- The skill dispatches `vault-librarian` INSERT with the structured payload and relays the committed path (verified by the skill's documented steps; the librarian INSERT path itself is already covered upstream).
