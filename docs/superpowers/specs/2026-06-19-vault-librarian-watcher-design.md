# vaultkeeper — Design Spec (supersedes the single-maintainer watcher draft)

**Date:** 2026-06-20
**Status:** Pending auditor approval (user delegated the approval gate to the auditor)
**Builds on:** the merged on-demand `vault-librarian` (PR #16)
**Repo:** `obsidian-plugin` (the keeper is plugin-owned — *not* a CEO playbook)

## Concept

The **vaultkeeper** is the obsidian plugin's keeper agent — *indistinguishable from the plugin itself*: shipped with it, present on every host the plugin runs on, invokable by anyone at any time. It is not a separate daemon bolted on; it is the plugin's purpose, incarnate as an agent that orchestrates a **toolbox of skills**. The index engine is just one skill in that toolbox.

This supersedes the prior single-ML-1-maintainer / CEO-playbook draft, which the user rejected on three grounds: the keeper should live on *every* host that writes to the vault (not one designated maintainer); it should be a dedicated plugin agent (not subsumed into the CEO playbook registry); and querying spans more than a hand-rolled index.

## Hosts & sync (the conflict model)

- **Keeper hosts = ML-1 (always-on Linux) + MacBook (MBP)** — the two hosts that run Claude Code + the plugin and that **Syncthing**-sync the vault between them. These are the only hosts that *write* the keeper's shared files.
- **FreeFileSync → iCloud → iOS** is a downstream distribution copy. The keeper does not run on iOS and never writes the iCloud copy; iOS note edits flow back as ordinary notes the keeper later indexes. Out of the conflict model.
- **Obsidian Sync:** not in use.
- So the multi-writer surface is exactly **two hosts over Syncthing** — conflict files are `.sync-conflict-*`.

## Index substrate: frontmatter + Obsidian Bases (NOT hand-rolled INDEX.md)

Verified: the vault has **no graph-DB / Dataview / query plugin**, but **Obsidian Bases is natively enabled** (currently unused — one empty `Untitled.base`), and frontmatter is **rich and consistent** across 1,742 notes (`date`, `tags`, `type`, `status`, `source`, `repo`, `pr`, `domain`, `project`, `session_*`, `branch`, `issue`…), much of it written by the plugin's own session-save. So the structured substrate already exists with no query layer on top.

The keeper therefore treats **frontmatter as the structured index** and **Obsidian Bases as the query/view engine**:
- Querying by structure (type/status/tag/domain/pr) is a **`.base` view** Obsidian computes **live** from frontmatter — no static index to reconcile. **Critical read/write split:** Bases views are computed only inside the Obsidian GUI; a headless keeper (cron/CLI) **cannot read a `.base` to answer a query**. So `.base` files are **write-only artifacts** the keeper *maintains* for the human's in-Obsidian view; the keeper's own headless query path is the **frontmatter walk / `find-notes`** (parsing YAML directly). No keeper code path ever reads a `.base` to produce an answer.
- The keeper's index-engine job shifts from "reconcile a static `INDEX.md`" to: **(a) validate frontmatter completeness/correctness against a schema, (b) maintain `.base` view definitions, (c) surface notes with missing/malformed frontmatter.** Coverage = *frontmatter completeness*, not INDEX.md membership.
- Hand-rolled `INDEX.md` MOCs become a **fallback** for human-readable curated indexes the user wants by hand, not the core mechanism.

**Frontmatter schema (v1):** a configurable required-key set in `obsidian.local.md` (default derived from the dominant existing keys, e.g. a note should have `tags` + `type`; per-domain overrides allowed). The keeper *surfaces* gaps; it does **not** auto-write frontmatter on the tick (auto-normalizing frontmatter across the vault is a large multi-writer surface — see write-safety). Filling a gap is an **agent-judgment** action (on-demand, user-visible), not deterministic-tick behavior.

## Architecture: two layers

**Deterministic substrate (shell, no LLM — what the tick runs):**
- Parse + validate frontmatter against the schema (text-only walk; exclude `.obsidian/`, `.trash/`, attachment dirs).
- Maintain `.base` view definitions (small declarative files).
- Compute raw surfacing **candidates**: notes with missing/malformed frontmatter, notes in `Inbox/`, open `[ask]` markers (frontmatter + body scan) with age, and raw cluster candidates (≥N notes sharing a tag/type/stem in a folder).
- Carry **write-safety** (below).
- Cheap, idempotent, deterministic — reuses/extends `note-hash.sh` for change-detection.

**The vaultkeeper agent (LLM — invoked on-demand or escalated-to for judgment):**
- **Query routing** — types the question and routes to the right backend (see below); synthesizes a cited, confidence-scored answer.
- **Management skills** (confirmed in scope): file/insert-with-judgment (route + template + dedup), decide cluster **promotion** from the substrate's raw candidates, fill/normalize frontmatter when asked, adjudicate quarantined conflicts.
- The agent **leans on the substrate**; it never replaces the cheap mechanical layer. An LLM is not spawned per tick.

## Query backends (typed by question — NOT interchangeable)

- **frontmatter + Bases / `find-notes`** → vault note **text & structure** ("what's written, where, by type/status/tag, what's unfiled, coverage gaps").
- **`recall`** → cross-**source** timeline (vault + git + GitHub + mem, stitched).
- **claude-mem graph search** → **work history** ("what did I work on / decide") — explicitly *not* a search of note contents (claude-mem indexes session observations, not the vault).

The keeper's value is choosing the right lens, not querying all of them.

## Watching

A lightweight **cron (ML-1) / launchd (MBP)** tick runs the **deterministic substrate** on each keeper host — *no LLM per tick*. This is what makes it a watcher (it acts even when you never invoke it). The tick is **plugin-owned and namespaced** (e.g. `com.nhangen.obsidian-vaultkeeper`) and documented in the README so a host cron/launchd audit surfaces it. (Stop-hook firing is an *opportunistic bonus* trigger on the active host — never the sole scheduler, since it never fires on an idle host.)

## Write-safety (Syncthing, two hosts — honest version)

The keeper's **shared writes** are: `.base` definitions, the digest (`Librarian.md`), and `Pending.md`. (User note edits and frontmatter are *not* keeper-gated; the keeper surfaces, the user/agent fills.)

- **Per-folder advisory lease** — reduces collision probability; gravitates to the active host. **It is NOT a lock** — the lease file syncs through the same Syncthing channel it would protect, so two hosts can briefly both hold it.
- **Correctness rests on:** (1) **deterministic host-priority election in the substrate (pre-LLM)** — given the set of live host-scoped claim files (`.keeper-claim-<host>`), every host independently computes the same owner via a total order; the non-owner defers. (2) **Quarantine-never-delete** — any `.sync-conflict-*` on a keeper-owned file is moved aside and surfaced, never auto-merged or deleted (no silent data loss). The lease only lowers how often this path fires.
- **Election runs in the shell substrate**, not as an agent decision — N agents must never race to decide ownership.

## Surfacing output

- **`Librarian.md`** (vault root, machine-owned, overwritten each scan, written atomically via temp-then-rename): current-state digest — frontmatter-gap notes, unfiled, open `[ask]`s, promotable clusters — with counts + `last_scan`. Header marks it machine-owned (edits don't persist).
- **`Pending.md`**: transition-gated — only **genuinely-new** items (vs the prior-scan snapshot in the local cache) append as `- [ ]` lines. No new items → only `last_scan` advances. (The disk-monitor-spammed-the-inbox-64-times lesson.)
- A Bases view (e.g. `_vaultkeeper.base`) can render the same gaps live inside Obsidian.
- **No CEO writes.** The keeper is plugin-owned; it does not touch `CEO/`.

## State store (local, non-synced, per host)

`.state` change-detection hashes + the prior-scan snapshot for transition detection live in `~/.cache/vaultkeeper/<vault-id>/` on each keeper host — never in the synced vault, so no cross-host `.state` race. First run on a cold cache snapshots silently (no surfacing flood).

## `/obsidian:ask` (the on-demand face)

Stays as the human entry point — now a façade over the same toolbox the tick uses. QUERY reads the live frontmatter/Bases substrate (+ routes to recall/claude-mem as typed); it does not write. If `now − last_scan > 2× interval`, it prepends a "⚠ index last maintained <T> ago" banner. INSERT creates the note (frontmatter + `[ask]` markers in the body); the tick harvests it.

## Out of scope (YAGNI / deferred)

CEO coupling (rejected); dangling-link detection (needs Obsidian link-grammar parsing — v2); dup auto-merge (surface only); embeddings; filesystem-event triggers (periodic poll suffices); auto-writing frontmatter on the tick (agent-judgment only).

## Testing (revert-fails)

Bash suites + a temp-vault fixture with a fake multi-host Syncthing layout. Each load-bearing invariant has a test that fails when its logic is reverted:
- Frontmatter validation flags a note missing a required key; passes a complete note.
- `.base` definition maintenance is idempotent.
- Surfacing candidates: unfiled, open-`[ask]`, cluster, frontmatter-gap each detected from fixtures.
- **Transition gating:** scan 2 with no change appends nothing; scan 3 after one new gap appends exactly one `- [ ]`.
- **Cold cache first run** snapshots silently.
- **Election:** given two host-claim files, both hosts compute the same owner; the loser writes nothing.
- **Quarantine:** a planted `.sync-conflict-*` on `Librarian.md` is moved aside + surfaced, never deleted.
- **Atomic digest:** `Librarian.md` written temp-then-rename; a hand-added line does not survive a scan (machine-owned).
- `/ask` QUERY writes nothing; staleness banner fires past 2× interval; INSERT note-only.
- `.state` lives under `~/.cache/vaultkeeper/`, not the vault.

## Audit trail

Five auditor passes during this brainstorm (`auditor-reviews-plans`): framing reorder; single-automated-writer hardening; the metaphor/convergence correction (single-writer is false once a human edits the index → restated; "converges therefore safe" rejected → lease is advisory, correctness = election + quarantine); the agent-vs-two-layer correction (don't collapse the deterministic substrate into an LLM); and the consolidation (backends typed by question; claude-mem = work-history not note-text; clustering = substrate emits candidates, agent decides). This spec also incorporates the verified facts: no query plugin but Bases enabled + rich frontmatter; Syncthing = ML-1↔MBP, FFS→iCloud downstream, Obsidian Sync unused.

(The auditor pass on this written spec is the gate the user delegated.)

## Plan-time follow-ups (from the approval audit — APPROVED)

All MED/LOW; none are design flaws — resolve in the implementation plan:
1. **State explicitly that no keeper path *reads* a `.base` to answer** — `.base` files are write-only human-view artifacts; the headless reader is the frontmatter walk / `find-notes`. (Now also clarified in the Index-substrate section above; the plan must keep an implementer from wiring a phantom Bases parser.)
2. **Test the election under a *partially-propagated* claim set**, not only two fully-synced claim files — to prove the converge-or-quarantine behavior holds mid-sync.
3. **Note that frontmatter-schema derivation is a one-time config-seeding step** (writes the required-key set into `obsidian.local.md`), not tick logic; the tick just validates against the configured schema.
