# Keeper CLI — Design

**Goal:** Expose the keeper's deterministic write primitives as a zero-AI CLI
(`scripts/keeper`) so any caller — a per-commit hook, a skill, the librarian
agent itself — performs vault writes through one implementation, without
dispatching a subagent for mechanical work.

**Origin (user, 2026-06-29):** "expose a vaultkeeper api/cli to handle things
like this so that the vaultkeeper is still used, but via command." Realizes the
original "spawned via hooks/endpoints; sits between any write" vision.

## The split — hands vs brain

The keeper has two layers, and writes divide cleanly:

- **CLI (`scripts/keeper`) = mechanical writes.** Deterministic, no LLM, no
  subagent: append a section to a known target; insert a pre-resolved note to a
  known folder. Safe to call from a PostToolUse hook on every commit.
- **vault-librarian agent = judgment writes.** Routing decisions, dedup-with-ask,
  low-confidence `Pending.md` escalation. Invoked only when a human-like decision
  is needed. The agent's mechanical steps *call the CLI* — it is not a second
  write implementation.

Both are "the keeper." The CLI is its hands; the librarian its brain.

## CLI surface (this iteration)

```
keeper append --vault <path> --target <relpath> [--section <heading>] \
              [--body-file <path>] [--init-file <path>]
keeper append --vault <path> --date <YYYY-MM-DD> ...   # --date → Daily/<date>.md
```

- **`--vault`** vault root. Explicit so a cost-sensitive caller (commit-capture)
  never pays a config read. If omitted, fall back to `resolve-config.sh`.
- **`--target`** note path relative to the vault, OR **`--date`** which resolves
  to `Daily/<date>.md`. Exactly one required.
- **`--section`** the heading line (e.g. `## 14:30 — Topic`). Optional; default
  `## <HH:MM> — entry`.
- **`--body-file`** file holding the section body (use a file, not an argv blob,
  so multi-line markdown survives). Stdin if omitted.
- **`--init-file`** content written ONLY when the target does not yet exist (the
  caller's frontmatter + H1 header). The CLI does NOT know templates — the
  caller owns the new-file header (commit-capture's repo header, the librarian's
  daily template). Keeps the CLI a pure mechanical primitive.

Behavior: resolve target under `--vault`; `mkdir -p` its parent; if absent,
write `--init-file` if given, else create the file empty (header is the caller's
job — an absent `--init-file` means "no header, just start with the section");
then append a blank line, the section heading, a blank line, and the body.
**No INDEX touch** (append to a dated note is not an INDEX event — matches the
librarian §APPEND rule). Print the written path.

**Concurrency: no lock.** The substrate libs use none, and `vault-index.sh`
deliberately dropped its bash-only trap for portability — adding a lock here
would diverge. macOS does not ship `flock(1)` (it would silently no-op — a
`command -v` presence-vs-capability trap), so a lock on the contended path is
worse than none. The append is a single `>>` (one open-append-close); the only
theoretical race is two writers *creating* the same target in the same instant,
and these targets are per-day / per-repo-per-day, so that race is not real in
practice. If a real contention case appears later, gate it then with a verified
primitive — do not speculatively add one now.

**Validation** (per `enum-config-typo-fallback` / `stub-cli-argv-validation`):
- Unknown subcommand or missing required arg → non-zero exit + stderr diagnostic.
- Exactly one of `--target` / `--date` required → else non-zero.
- **`--vault` must be an existing directory** → else non-zero (don't `mkdir` a
  vault-shaped tree at a typo'd path).
- **Path-traversal guard:** the resolved absolute target must stay under the
  resolved `--vault` (realpath prefix check) → else non-zero. A
  `--target ../../etc/foo` must be rejected, not written.

## Callers

1. **commit-capture** → `keeper append --vault <inline> --target
   Projects/Development/<org_repo>/<date>.md --section "## <time> — <hash>"
   --body-file <ctx> --init-file <repo-header>`. The context bullets — the
   skill's real value — are synthesized from the conversation, which lives only
   in the agent's context; the PostToolUse hook (`commit-capture.sh`) has no
   conversation access, so the *turn* must happen regardless. The CLI does not
   remove that turn; what it removes is the **subagent dispatch** (and the
   config read) the keeper-save→librarian path would have added. That is the
   accurate win, and it preserves commit-capture's deliberately low cost.
2. **vault-librarian §APPEND** → runs `keeper append` instead of appending by
   hand, so the CLI is the one append implementation. For a daily note it passes
   `--date` and an `--init-file` rendered from `Daily/_Daily Template.md`.
3. **daily-note** is unchanged this iteration (it already reaches APPEND via the
   librarian, which now routes through the CLI). A later pass can point it at the
   CLI directly to drop its subagent too.

## Out of scope (this iteration)

- `keeper insert` (pre-resolved note + INDEX link via `vault_index_apply`). The
  natural next subcommand, but not needed for commit-capture. Designed so the
  surface extends cleanly.
- Moving routing/dedup judgment into the CLI — that stays in the agent (the
  "brain" half), per the standing "sole writer now, brain later" decision.

## Risk

Low/additive. New script + new tests; no existing path changes behavior until a
caller opts in. commit-capture's migration is the only behavior change, and it
*reduces* cost. The librarian §APPEND pointing at the CLI is a prose change that
preserves its current semantics (create-on-absent, append, no INDEX).
