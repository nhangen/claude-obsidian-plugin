# Keeper CLI `insert` — Design

**Goal:** Add `keeper insert` so a caller that already built a complete,
pre-resolved note (save-conversation) can write it through the CLI — no
subagent. It preserves the librarian INSERT's behavior *for the resolved path*:
write the file, append the human link to the folder INDEX, sync index state, and
link the note into today's daily `## Session Links`. It deliberately drops two
librarian-INSERT steps the resolved path never used: template application
(save-conversation already renders its full Output Format note) and the
`[ask]`/`Pending.md` unknown-field flow (the resolved caller builds a complete
note and owns its own confirmation via `capture_needs_confirmation`).

**Why:** finishes the "no mechanical write spawns a subagent" goal. commit-capture
and the librarian APPEND already use the CLI; `insert` extends it to the
resolved-new-file case so save-conversation drops its keeper-save→librarian
subagent for the common path.

## Surface

```
keeper insert --vault <path> --target <relpath.md> --body-file <path> \
              [--title <text>] [--session-link-date <YYYY-MM-DD>]
```

- **`--target`** full vault-relative path incl. filename (caller computed it).
  Same guards as `append`: relative, no `..`, under `--vault`.
- **`--body-file`** the COMPLETE note (frontmatter + body) the caller built. The
  CLI writes it verbatim — caller owns the template, same philosophy as
  `append --init-file`. (The librarian's "apply a template" step was redundant
  for save-conversation, which already renders its own Output Format note.)
- **`--title`** link text for the INDEX / Session-Links entry. Default: the
  filename without `.md` (date prefix KEPT, so `[[2026-06-29-slug]]` resolves to
  the file — the librarian's filename-based INDEX convention).
- **`--session-link-date`** when given, append `- [[<title>]]` under
  `## Session Links` in `Daily/<date>.md` (create the file/section if absent).
  Preserves the librarian's "link session notes into the daily note" behavior.

## Behavior

1. Validate (reuse `append`'s guards): `--vault` is an existing dir; `--target`
   relative, no `..`, not absolute; `--body-file` exists.
2. **Refuse on exists.** If the target already exists → non-zero + stderr. The
   caller owns dedup/collision (save-conversation runs same-day dedup and
   collision-suffixing before calling). `insert` never overwrites — that
   distinguishes it from `append`.
3. `mkdir -p` the parent; write `--body-file` to the target verbatim.
4. **Write the file (must exist before state sync), append INDEX link, sync state:**
   - Append `- [[<title>]]` to `<folder>/INDEX.md` (create `INDEX.md` with an
     `# <folder> Index` header if absent). Append-only; never rewrite.
   - Source `note-hash.sh` + `vault-index.sh`; run
     `vault_index_apply "<folder>" "<folder>/INDEX.md"`. **Mechanism (corrected):**
     `vault_index_apply` keys on *note filenames in the folder*, not on INDEX.md
     content. Because the note file already exists (step 3), apply records it in
     the index *state* file; a later QUERY's `vault_index_plan` therefore won't
     emit it as ADDED, so QUERY won't append a *second* human link. The
     no-double-link guarantee comes from the note being in state — not from the
     human link's append order. (`INDEX.md` does not self-register: plan skips
     the file whose basename equals the passed index, `vault-index.sh:47`.)
5. **Session Links** (if `--session-link-date`, validated `YYYY-MM-DD`): in
   `Daily/<date>.md`, ensure a `## Session Links` section exists (append the
   header — with a leading-newline guard if the file has trailing content;
   create the daily file with a minimal header if absent), then append
   `- [[<title>]]` under it. Idempotent via `grep -qxF -- "- [[<title>]]"`
   (fixed-string, whole-line, matching the librarian's emit format,
   `vault-librarian.md:72`) — skip if already present.
6. Print the written target path.

## Portability / safety

- Sourcing `vault-index.sh` under the CLI's `#!/usr/bin/env bash` is fine; the
  lib is already zsh-clean (the RETURN-trap fix) and the keeper-cli test runs the
  binary under zsh, so `insert` is covered there too.
- No lock (same rationale as `append`); `insert` refuses-on-exists so two racing
  inserts to the same path can't both succeed silently — the second sees the
  file and errors.

## Retrofits (the "finish") — the dispatch moves into keeper-save

The retrofit target is **keeper-save SKILL**, not the individual skills. Today
keeper-save *always* dispatches the vault-librarian for both INSERT and APPEND
(`keeper-save/SKILL.md` Step 4), so editing save-conversation alone would be a
no-op — the subagent lives one layer down. Make keeper-save the router:

- **APPEND** → run `keeper append` (the CLI). Always mechanical (target/date
  given); never needs the librarian.
- **INSERT with `resolved: true`** → run `keeper insert` (the CLI). Pass through
  a new optional `session_link_date` payload field as `--session-link-date` so
  session notes keep their daily `## Session Links` entry (the librarian did this
  implicitly; the CLI needs it explicit, so it's opt-in per payload — non-session
  callers omit it).
- **INSERT without `resolved`** → dispatch the vault-librarian (needs routing +
  dedup judgment). Unchanged.

This drops the subagent for **daily-note** (APPEND), **save-conversation** new
notes (resolved INSERT), and save-conversation twin-append — all in one edit,
without touching those skills' calls. The only skill edit: **save-conversation**
adds `session_link_date: <today>` to its new-file INSERT payload, to preserve the
Session-Links linkage the librarian used to do implicitly. save-conversation's
substrate INSERT stays unresolved → librarian (keeps dedup), unchanged.

## Out of scope (unchanged)

- The "sole brain" step (routing/dedup/MOC judgment into the keeper) — still
  deferred.
- save-conversation's substrate INSERT keeps using the librarian (it wants the
  keeper's dedup; `insert` refuses-on-exists rather than dedups).

## Risk

Low/additive. New subcommand + retrofits of two skills' write calls to a cheaper
path that preserves INDEX + Session-Links behavior. The break-risk is losing
INDEX/Session-Links linkage on the retrofit — the design replicates both, and a
test asserts the INDEX link + Session-Links entry land.
