# Vaultkeeper "Sole Brain" — Shared Routing/Dedup Libraries

**Issue:** nhangen/claude-obsidian-plugin#26
**Goal:** Give each "where does this note go / is it a duplicate" rule a single
authoritative source, so the rules stop being re-described in multiple skill/agent
files and drifting apart.

## Background

The vaultkeeper's *writer* is unified (the `keeper` CLI). Its *decision logic* is
not: the rules for folder-routing, allow-list validation, and same-day dedup are
written in several places. Grepped duplication:

| Rule | save-conversation | vault-librarian | create-note | Kind |
|------|-------------------|-----------------|-------------|------|
| Allow-list validation | full prose | full prose | full prose | deterministic |
| Same-day dedup (glob + tokenize + Jaccard) | full prose | dedup scan | — | deterministic |
| Semantic routing (topic → domain) | full prose | own prose | *references* save-conversation | LLM judgment |
| Cross-domain tiebreaker | full prose | — | — | (single site) |
| MOC-promotion (cluster detect + prompt) | full prose | — | — | (single site) |

Two rules are **deterministic and copied 2–3×** (allow-list, dedup) — the real
drift risk, and fully scriptable. Semantic routing is **LLM judgment** and cannot
be scripted without going brittle.

## Design principle

"Write the rules once" = **one authoritative source per rule**, not "collapse
everything into bash":

- **Deterministic rules → one shared shell library**, sourced by every consumer
  (the pattern already used for `note-hash.sh` / `vault-index.sh`).
- **Fuzzy routing → one canonical prose source**, referenced by the skills that
  need it — and that prose reads its folder set from the taxonomy table, never
  hardcodes folder names.

Rejected alternatives:
- **`keeper route` CLI owns the whole decision** — fuzzy topic→folder in
  deterministic bash is brittle and higher-cost; makes routing worse.
- **Librarian becomes the sole brain** — re-adds a subagent dispatch to the
  common save/create path, regressing the cost work that made the keeper CLI the
  default writer.

## Components

### 1. `scripts/lib/allowlist-validate.sh` (new)

Sourced; depends on `resolve-config.sh` for the config path.

- `allowlist_list [config]` — parse the `## Project Taxonomy` table, emit each
  `Vault path` value (one per line), trailing slash stripped. The single source
  of "valid top-level folders."
- `allowlist_validate <target> [config]` — normalize target + each allow-list
  entry (strip trailing `/`, lowercase — macOS APFS is case-insensitive); compute
  the target's top-level prefix; succeed if any entry is a prefix (dated
  subfolders and per-repo namespacing under an allow-listed root are valid). On
  failure: print the closest match (Levenshtein on the top-level component, in the
  taxonomy's original casing) and the standard refusal message to stderr, exit
  non-zero. Never creates folders.

### 2. `scripts/lib/dedup-scan.sh` (new)

Sourced; pure functions, no config dependency.

- `tokenize_slug <slug>` — split on `-`, lowercase, drop purely-numeric tokens
  and 1-char tokens, keep 2-char tokens (`pr`, `om`, `ai`). Emit tokens one per
  line. **This is the one tokenizer** — MOC-promotion sources it too.
- `jaccard <slug-a> <slug-b>` — token Jaccard of the two slugs via
  `tokenize_slug`; echo a decimal 0.00–1.00.
- `dedup_same_day <folder> <date> <slug> [threshold]` — glob
  `<folder>/<date>-*.md`, score each existing slug's Jaccard against `<slug>`,
  echo the highest-scoring `path\tscore` when `score >= threshold` (default
  `0.4`), else nothing. Caller owns the append/new prompt.

### 3. Consumers refactored to call, not re-describe

- **save-conversation** — allow-list step → `allowlist_validate`; same-day dedup
  step → `dedup_same_day`; MOC-promotion tokenizer → `tokenize_slug` (source
  `dedup-scan.sh`). The prompt/interaction prose stays (single site).
- **create-note** — allow-list step → `allowlist_validate`.
- **vault-librarian** — allow-list + dedup-scan → the libs. **Migration check:**
  verify the librarian's execution context sources `scripts/lib/` the same way
  the CLI/skills do (it runs via `${CLAUDE_PLUGIN_ROOT}`); confirm before
  switching, do not assume parity.
- **keeper CLI (`insert`)** — optionally call `allowlist_validate` as a
  defense-in-depth guard (today it only guards path traversal; the caller resolves
  the target). Additive, not required for the drift fix.

### 4. Canonical routing prose

Move the semantic-routing description to a **neutral canonical home** — the
config's `## Routing Rules` section (already the taxonomy source) — so the
authority is not hostage to one skill file's lifecycle. `save-conversation`,
`create-note`, and `vault-librarian` reference it. **The routing prose must not
enumerate example folders inline**; it states that valid targets are whatever
`allowlist_list` emits from the taxonomy table. One source (the table), read by
both the router (LLM) and the validator (bash) — closes the "LLM routes to a
folder the validator then rejects" seam.

## Testing

TDD, one lib at a time, each with a mutation check (revert the fix → test fails).

- **allowlist-validate:** valid top-level prefix; dated subfolder under a root;
  per-repo namespaced path; refuse unknown top-level + correct closest-match;
  case-insensitive match; `allowlist_list` emits exactly the taxonomy rows.
- **dedup-scan:** `tokenize_slug` drops numeric/1-char, keeps 2-char; `jaccard`
  known pairs; `dedup_same_day` finds a same-day match above threshold, ignores
  below, ignores other-day files.
- **shared-tokenizer parity fixture (closes the HIGH seam):** one slug fixture,
  assert the token set used by `dedup_same_day` equals the set MOC-promotion
  would use — they must be the *same function*, not two implementations.
- **zsh portability:** run both libs' tests under `zsh` (the repo's existing
  convention), asserting no bash-only constructs.

## Out of scope

- Cross-domain tiebreaker and MOC-promotion *prompt* logic (single-site today —
  not duplicated). Only the shared `tokenize_slug` is extracted from MOC.
- The larger "librarian as sole judgment actor" reshaping — explicitly rejected
  above; the keeper stays the cheap default writer.

## Risk

Low/additive. Two new sourced libs matching an established pattern, plus
mechanical retrofits of prose to lib calls. The two HIGH seams (routing prose
pointing at the table via `allowlist_list`; one shared tokenizer) are closed by
design and asserted by tests. The one migration hazard (librarian lib-sourcing)
is gated by an explicit pre-switch verification.
