# Keeper as Sole Writer — Design

**Goal:** Every vault note-write funnels through the keeper (keeper-save →
vault-librarian), so the keeper is the only code path that creates/appends a
note file and touches an INDEX. Kills the dual-path where some skills delegate
writes and others write directly.

**Decision (user, 2026-06-29):** Sole *writer* now, sole *brain* later. Skills
keep their own cognition (routing decision, dedup decision, inference,
substrate, MOC). They stop touching disk directly — the final write is handed
to the keeper. Moving the routing brain *into* the librarian is a deliberate
later step, not this one.

## The seam — pre-resolved writes

A skill like `save-conversation` already routes (precedence tiebreaker +
cross-domain cache) and dedups (same-day Jaccard) before it writes. If it hands
the keeper an INSERT and the keeper *re-routes* and *re-dedups*, the two brains
conflict (double prompts, a folder ignored in favor of the keeper's own route).
So the keeper's INSERT gains a single **pre-resolved** opt-in:

- **`resolved: true`** is the SOLE trigger that changes keeper behavior. It
  tells the keeper the caller already owns routing AND dedup: write to
  `folder_hint` as-is, skip routing, skip the dedup scan, then apply template +
  link INDEX. Validated as a literal: only `true` enables the skip;
  absent/any-other-value = full keeper routing + dedup.
- **`folder_hint` semantics are UNCHANGED for every non-resolved caller.**
  `hari-seldon` and `create-note` already pass `folder_hint` and expect the
  keeper to still route + dedup — that behavior is preserved. `folder_hint`
  becomes authoritative ONLY in combination with `resolved: true`. This is the
  cut that keeps the change strictly additive: a caller passing `folder_hint`
  alone behaves exactly as before.

This is additive — existing INSERT callers (which pass no `resolved`) behave
exactly as before.

## save-conversation's three write surfaces

1. **New-file save** → `keeper-save` INSERT with `resolved: true`,
   `folder_hint: <the folder save-conversation already resolved>`, `body: <the
   built session note>`, `type`, `links`. save-conversation keeps inference,
   routing, same-day dedup, MOC detection as pre-steps; only the disk write
   moves to the keeper.
2. **Same-day-twin append** → `keeper-save` APPEND with `target: <the twin file
   save-conversation chose>`, `section: ## HH:MM — <Title>`, `body: <the full h3
   sub-block structure, built by save-conversation>`. The librarian writes
   `body` verbatim, so save-conversation must hand over the complete h3 nesting
   (Summary/Findings/Details/Related as `###`) — the keeper does not
   reconstruct it. The twin always exists, so APPEND's create-on-absent never
   fires. APPEND's no-INDEX is acceptable here: the INDEX is file-level, the
   twin is already indexed as a file, and a new `## HH:MM` *section* is not
   separately tracked. save-conversation already made the dedup decision.
3. **Research-substrate object** → save-conversation runs an explicit substrate
   dedup pre-step (scan `Research-Substrate/<type>` for an existing object on
   the same claim/slug), then files via `keeper-save` INSERT with
   `resolved: true`, `folder_hint: Projects/Physics-AI-ML/Research-Substrate/<type>`.
   The caller-side dedup is required because save-conversation has no same-day
   dedup for substrate objects, and `resolved: true` skips the keeper's dedup —
   without the pre-step, duplicate claims/evidence could accumulate silently.

## Explicitly out of scope (stays native)

- **MOC-promotion file *moves*.** Moving existing notes into a `<Stem>/notes/`
  subfolder is structural reorganization, which the librarian already delegates
  to `vault-organizer` (`vault-librarian.md:92`). Moves are not note-writes;
  they stay where they are. (The README index that MOC creates is a note-write
  and may later go through the keeper, but it is bundled with the move logic, so
  it stays with the move for now.)
- **commit-capture.** Migrated next, as a separate change (APPEND-shaped, like
  daily-note). Not in this plan.
- **Moving the routing brain into the librarian.** The deferred "sole brain"
  step.

## Risk

Low. The INSERT change is additive (pre-resolved is opt-in). save-conversation's
change is a prose skill edit that swaps direct Write/Edit for keeper-save calls;
its routing/dedup/MOC logic is unchanged. The one thing to verify by test: the
librarian honors `folder_hint`-authoritative + `resolved`-skip, so a
pre-resolved INSERT does not re-route or re-dedup.
