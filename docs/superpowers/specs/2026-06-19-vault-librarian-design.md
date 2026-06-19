# vault-librarian — Design Spec

**Date:** 2026-06-19
**Status:** Approved (brainstorming → spec); pending implementation plan
**Component of:** `obsidian` Claude Code plugin (dev tree `~/ML-AI/claude/obsidian-plugin`)

## Problem

A long-lived vault (~1,719 notes, 579 MB at `/Users/nhangen/Documents/Obsidian`) needs a single component that (1) answers vault queries quickly and accurately, (2) enters new information without back-and-forth, and (3) "knows everything there is to know about the vault."

The vault already has a hand-designed markdown knowledge layer — `VAULT.md` (top-level map), `Profile.md` (identity/constraints), `Pending.md` (`[ask]` queue), `Decisions/INDEX.md`, `Artifacts/INDEX.md`, `People/`, `Templates/`, and domain MOCs — but nothing reads it as a first-class query/insert surface or keeps it current. The `obsidian` plugin already covers capture (`session-save`, `commit-capture`), retrieval (`find`, `recall`), authoring (`new`, `daily`, `save`), and reorg (`vault-organizer` subagent). The missing piece is the **knowledge layer that makes the existing markdown indexes canonical and self-maintaining.**

This is a wiring problem, not a new-index-engine problem. No embeddings, no vector store, no claude-mem corpus — the existing markdown INDEX/MOC files are the index.

## Honest contract

The librarian **knows everything that is indexed, freshness-confirmed at query time, and reports indexing gaps when a slice is incomplete.** "No back-and-forth" holds for INSERT except the deliberate low-confidence-routing → `[ask]` exception. These bounds are stated up front so "know everything" is a verifiable contract, not aspiration.

## Architecture

A stateless `vault-librarian` **subagent** in the `obsidian` plugin, sibling to `vault-organizer`. Because a subagent returns only final text and holds no state between dispatches, **the markdown index is the product** — per-call bootstrap (read `VAULT.md` + `Profile.md` + the routed `INDEX.md`) is what makes it both cheap and knowledgeable. Reading dozens of index files happens in the subagent's own context window; the main conversation gets back only the answer or the write confirmation.

The librarian is a **knowledge layer beside the existing skills**, not a replacement. `find`/`recall`/`new`/`daily`/`save` keep working unchanged; the librarian adds the index-grounded surface they can call into.

### Operations

Two everyday operations plus a non-everyday health pass.

#### QUERY — "what do we know about X / where is Y / what did we decide about Z"

1. **Bootstrap:** read `VAULT.md` (map) + `Profile.md` (constraints).
2. **Route:** map the question → domain folder(s) + relevant `INDEX.md` via the `obsidian.local.md` taxonomy + keyword routing rules. Ambiguous/cross-domain → fall back to the `VAULT.md` map and widen.
3. **Refresh the slice** (see Freshness) so the INDEX is trustworthy.
4. **Coverage invariant:** every note in the routed folder is either present in that folder's INDEX or reported as an indexing gap. A known-incomplete slice lowers reported confidence — never a confident answer from a partial slice. The coverage check is a **name-only set-diff** (folder filenames vs INDEX keys); it never opens notes.
5. **Narrow:** open only the few notes the INDEX points at.
6. **Raw-text fallback:** if the INDEX slice returns **zero candidate notes OR confidence below threshold**, QUERY calls the existing `find` skill (raw text search) rather than reimplementing search. Not invoked reflexively on every query.
7. **Return:** answer + note-link citations + confidence + any relevant `[ask]` gaps.

#### INSERT — "remember / file / record this" (the no-back-and-forth path)

1. **Route** content → target folder (taxonomy + `Profile.md` context). The routing decision is a guess the agent makes, so INSERT **always reports the chosen folder** in its output, and **low-confidence routing becomes an `[ask]` in `Pending.md`** rather than a silent commit.
2. **Dedup:** check the routed folder's INDEX + Jaccard similarity (`dedup_jaccard_threshold: 0.4`). A near-dup is **surfaced/logged, never silently merged** — false-positive merges are silent data loss.
3. **Write:** create/append using the matching `Templates/` template; append a link to the correct INDEX (`Decisions/INDEX.md`, `Artifacts/INDEX.md`, or the domain MOC); link session notes to the daily note under `## Session Links` per vault convention.
4. **Unknowns:** genuine unknown fields → `[ask]` markers in the note + `Pending.md` entries, deferring questions into the existing correctable queue instead of interrogating the user mid-task.
5. **Restamp** the touched INDEX `last_reconciled`; **return** what was written / where + a one-line summary.
6. **Destructive ops:** any move/delete → dry-run manifest + explicit user approval, reusing the `vault-organizer` rollback-manifest pattern. Respect `strict_domains: true`.

#### Health pass — not an everyday op

Vault-wide dangling-link / orphan scan. Delegates structural reorganization to the existing `vault-organizer` subagent. Slice-level reconcile is **not** a user-facing operation — it is folded into QUERY and INSERT.

### Freshness (on-demand, two-stage)

The vault syncs via Syncthing and receives git/commit-capture writes — both rewrite file mtimes — so **mtime alone cannot be the correctness signal.** A single folder-stat pass feeds both the coverage check and the freshness candidate-filter (no second traversal).

- **Candidate filter (cheap):** `find <folder> -newer <INDEX.last_reconciled>`, comparing UTC epoch values — selects *maybe-changed* files.
- **Confirm (correct):** compare a stored per-entry hash in the INDEX → reconcile only *actually-changed* files. This stops a Syncthing mtime-bump from triggering a full re-scan.
- **Hash scheme — exactly one, parse-validated:** `size + full-body content hash` (single algorithm). First-line-only is rejected because it misses body-only edits. An INDEX entry whose hash field does not parse to the expected shape is forced into the cold-start reconcile path — never a silent skip. (~40 bytes/note × 1,719 ≈ 70 KB total across all INDEXes — negligible.)
- **Cold start:** an INDEX with no `last_reconciled` → reconcile the whole folder once.
- **Reconcile = cheap diff:** add missing INDEX entries, drop entries pointing at deleted/moved notes, update titles; full content summarization only for genuinely new notes; then restamp `last_reconciled`.

### Data model

- Each `INDEX.md` frontmatter gains `last_reconciled:` (UTC ISO-8601) and per-entry hashes (`size + body-hash`).
- `VAULT.md` remains the top-level map.
- No new file types beyond what `VAULT.md` already prescribes; the librarian *maintains* the existing structure.
- **INDEX soft size cap:** an INDEX exceeding the cap splits, so per-call bootstrap cost does not grow with the vault.

### Entry points

- A slash command / skill (e.g. `/obsidian:ask`) dispatches the subagent for QUERY.
- INSERT is reachable directly and reusable by `new`/`save`.
- `find`/`recall` remain as-is; `recall` may call QUERY. Dependency graph is a strict DAG: `recall → QUERY → find` (find never calls QUERY).

### Boundaries vs existing skills (drift prevention)

- **QUERY** = index-grounded, cited, confidence-scored answer.
- **`find`** = raw text search (QUERY's fallback target).
- **`recall`** = cross-source timeline (vault + git + PR + claude-mem); may call QUERY.

## Out of scope (YAGNI)

Embeddings / vector index, claude-mem corpus integration, Obsidian-native plugin (Dataview/Smart Connections), write-path hooks, scheduled/nightly rebuilds. On-demand freshness with the two-stage filter makes these unnecessary.

## Testing

A fixture mini-vault (`VAULT.md` + a couple `INDEX.md` files + sample notes + `Templates/`). Tests must **fail when the reconcile/dedup logic is reverted**:

- Slice routing selects the correct folder + INDEX for a representative query.
- mtime+hash selects only truly-changed files:
  - **Syncthing mtime-bump fixture** (mtime newer, content identical) → must **NOT** re-summarize.
  - **Body-edit-only fixture** (title/first line unchanged, body changed) → **MUST** re-summarize.
- INDEX reconcile adds missing entries and drops dangling ones.
- Coverage check flags an un-indexed note in the routed folder (name-only set-diff, no content reads).
- Near-dup INSERT surfaces the duplicate rather than silently merging.
- `[ask]` entry queued in `Pending.md` for an unknown field on INSERT.
- Destructive op (move/delete) produces a dry-run manifest and requires approval.
- Cold-start (INDEX with no `last_reconciled`) reconciles the whole folder once.
- Malformed hash field forces an entry into cold-start reconcile, not a silent skip.

## Audit trail

Three independent auditor passes during brainstorming (`auditor-reviews-plans`):

1. **Framing audit** — corrected anchoring on "agent vs tool" (a packaging detail); flagged that the real forks are index/freshness strategy and write-safety; directed investigation of claude-mem/serena coverage (found: claude-mem corpus not over the vault, serena code-only) and surfaced the pre-existing `VAULT.md` markdown index layer.
2. **Design audit** — HIGH: stateless-subagent "knows everything" depends entirely on index coverage (→ coverage invariant); HIGH: mtime unreliable under Syncthing/git (→ two-stage freshness). MED: report routing choice / `[ask]` low-confidence; cut MANAGE to a health pass; QUERY calls `find` instead of reimplementing; near-dup surfaces not merges; INDEX soft size cap.
3. **Revised-design audit** — no HIGH findings, shippable. Folded in: single folder-stat pass shared by coverage + freshness; one parse-validated hash scheme; confirm-hash covers full body not first line; precise `find` fallback trigger; honest contract stated explicitly.
