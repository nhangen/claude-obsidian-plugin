# vault-librarian Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a stateless `vault-librarian` subagent to the `obsidian` plugin that answers index-grounded vault queries and inserts new notes without back-and-forth, backed by a self-maintaining markdown INDEX layer with on-demand two-stage freshness.

**Architecture:** Deterministic, unit-testable shell helpers (`note-hash.sh`, `vault-index.sh`) do the freshness/coverage/reconcile math; a subagent markdown file (`agents/vault-librarian.md`) orchestrates QUERY/INSERT/health by calling those helpers and reusing the plugin's existing taxonomy routing prose; a thin skill + command (`/obsidian:ask`) dispatches the subagent. Per-INDEX machine state (per-entry `size:sha` hashes + `last_reconciled` epoch) lives in a hidden sidecar `.<index>.state` file so `INDEX.md` is only ever append-edited.

**Tech Stack:** Bash (POSIX-ish, macOS + Linux portable), markdown skills/agents, existing `scripts/lib/resolve-config.sh` config resolver. No new runtime dependencies.

## Global Constraints

- Work in the worktree `~/ML-AI/claude/obsidian-plugin-vault-librarian` on branch `nh/feat/vault-librarian-spec`. Never commit on `master`; never touch the 8 unrelated dirty files in the main clone.
- Commit messages: no "claude", "co-authored", or "anthropic" anywhere.
- Test before every commit (`bash tests/<file>.sh` must pass); do not push (push requires explicit user approval).
- All scripts portable across macOS (`stat -f %m`, `shasum`) and Linux (`stat -c %Y`, `sha256sum`) via wrapper functions.
- Skills resolve the vault via `CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"` then `vault_path:`; if empty, tell the user to run `/obsidian:setup` and stop.
- Hidden sidecar state files are named `.<INDEX-basename-without-.md>.state`; they are machine-only and never shown as notes.
- Hash scheme is exactly one shape: `size:sha256hex` (`^[0-9]+:[0-9a-f]{64}$`). A malformed stored hash forces that entry into the reconcile path — never a silent skip.
- Write-safety: `INDEX.md` is append-only for links; any note move/delete requires a dry-run manifest + explicit user approval (reuse `vault-organizer` rollback pattern); respect `strict_domains: true`.

---

### Task 1: Note hashing library

**Files:**
- Create: `scripts/lib/note-hash.sh`
- Test: `tests/note-hash.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `note_hash <file>` → prints `"<bytes>:<sha256hex>"` for the file's full content.
  - `note_hash_valid <string>` → exit 0 iff string matches `^[0-9]+:[0-9a-f]{64}$`.
  - `file_mtime <file>` → prints integer epoch mtime (portable).
  - `now_epoch` → prints current integer epoch.

- [ ] **Step 1: Write the failing test**

```bash
# tests/note-hash.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/note-hash-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

printf 'hello world\n' > "$TMP/a.md"
H1="$(note_hash "$TMP/a.md")"
note_hash_valid "$H1" || fail "note_hash output not valid shape: $H1"

# identical content -> identical hash
printf 'hello world\n' > "$TMP/b.md"
[ "$(note_hash "$TMP/b.md")" = "$H1" ] || fail "same content should hash equal"

# body change -> different hash
printf 'hello WORLD\n' > "$TMP/a.md"
[ "$(note_hash "$TMP/a.md")" != "$H1" ] || fail "changed content should hash differently"

# validity rejects junk
note_hash_valid "garbage" && fail "should reject 'garbage'"
note_hash_valid "12:abc" && fail "should reject short hex"
note_hash_valid "" && fail "should reject empty"

# mtime + now are integers
M="$(file_mtime "$TMP/a.md")"; [[ "$M" =~ ^[0-9]+$ ]] || fail "file_mtime not integer: $M"
N="$(now_epoch)"; [[ "$N" =~ ^[0-9]+$ ]] || fail "now_epoch not integer: $N"

echo "PASS: note-hash"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/note-hash.sh`
Expected: FAIL — `scripts/lib/note-hash.sh` does not exist (source error).

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/note-hash.sh
#!/usr/bin/env bash
# note-hash.sh — content hashing + portable stat helpers for the librarian.

sha256_of() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "${out:-}" ] && command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$out"
}

note_hash() {
  local f="$1" size sha
  size="$(wc -c < "$f" | tr -d ' ')"
  sha="$(sha256_of "$f")"
  printf '%s:%s\n' "$size" "$sha"
}

note_hash_valid() {
  [[ "$1" =~ ^[0-9]+:[0-9a-f]{64}$ ]]
}

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"
}

now_epoch() {
  date +%s
}
```

Note: `sha256_of` checks output emptiness sequentially (not chained `command -v`) per the `command-v-presence-vs-success` rule — Homebrew GNU shims can shadow without behaving identically.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/note-hash.sh`
Expected: `PASS: note-hash`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/note-hash.sh tests/note-hash.sh
git commit -m "feat: add note-hash lib for librarian freshness checks"
```

---

### Task 2: Index plan (coverage + two-stage freshness)

**Files:**
- Create: `scripts/lib/vault-index.sh`
- Test: `tests/vault-index-plan.sh`

**Interfaces:**
- Consumes: `note-hash.sh` (`note_hash`, `note_hash_valid`, `file_mtime`).
- Produces:
  - `index_state_file <index_file>` → prints sidecar path `<dir>/.<base>.state`.
  - `state_last_reconciled <state_file>` → prints epoch or empty.
  - `state_hash_for <state_file> <filename>` → prints stored `size:sha` or empty.
  - `vault_index_plan <folder> <index_file>` → emits TSV lines `ACTION<TAB>filename`, where ACTION ∈ `ADD` (coverage gap / new, no state entry — name-only, no content read), `CHANGED` (mtime newer AND hash differs), `DROP` (state entry whose file is gone). Files with a valid stored hash and mtime ≤ last_reconciled emit nothing (trusted). Malformed stored hash → `CHANGED` (forced reconcile). Empty `last_reconciled` (cold start) → every stored-entry file is hash-checked.

State file format (one entry per line, TSV): first line `# last_reconciled:<epoch>`, then `<filename>\t<size:sha>`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/vault-index-plan.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
plan_has() { grep -qxF "$1" <<<"$2" || fail "expected plan line: $1"$'\n'"got:"$'\n'"$2"; }
plan_lacks() { grep -qxF "$1" <<<"$2" && fail "did not expect plan line: $1"; return 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-index-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
F="$TMP/Decisions"; mkdir -p "$F"
IDX="$F/INDEX.md"; printf -- '- [[a]]\n- [[b]]\n' > "$IDX"
printf 'note A body\n' > "$F/a.md"
printf 'note B body\n' > "$F/b.md"
printf 'brand new note\n' > "$F/c.md"

STATE="$(index_state_file "$IDX")"
[ "$STATE" = "$F/.INDEX.state" ] || fail "wrong sidecar path: $STATE"

# Seed state: a and b indexed with correct hashes, last_reconciled in the past.
{
  echo "# last_reconciled:1000"
  printf 'a.md\t%s\n' "$(note_hash "$F/a.md")"
  printf 'b.md\t%s\n' "$(note_hash "$F/b.md")"
} > "$STATE"

# Make a.md and b.md look OLD (mtime <= last_reconciled), c.md is new and unindexed.
touch -t 197001010000 "$F/a.md" "$F/b.md"

PLAN="$(vault_index_plan "$F" "$IDX")"
plan_has  "ADD"$'\t'"c.md" "$PLAN"          # coverage gap, no content read needed
plan_lacks "CHANGED"$'\t'"a.md" "$PLAN"     # old mtime + matching hash -> trusted
plan_lacks "CHANGED"$'\t'"b.md" "$PLAN"

# Syncthing mtime-bump: touch a.md NEWER than last_reconciled but DON'T change content.
touch "$F/a.md"
PLAN="$(vault_index_plan "$F" "$IDX")"
plan_lacks "CHANGED"$'\t'"a.md" "$PLAN"     # mtime newer but hash matches -> NOT changed

# Body-edit-only: change b.md content (and thus mtime).
printf 'note B body EDITED\n' > "$F/b.md"
PLAN="$(vault_index_plan "$F" "$IDX")"
plan_has  "CHANGED"$'\t'"b.md" "$PLAN"      # mtime newer AND hash differs -> changed

# Dangling: state references a deleted file.
printf 'gone.md\tjunk\n' >> "$STATE"
PLAN="$(vault_index_plan "$F" "$IDX")"
plan_has "DROP"$'\t'"gone.md" "$PLAN"

# Malformed stored hash -> forced reconcile (cold path), not silent skip.
{
  echo "# last_reconciled:1000"
  printf 'a.md\tNOTAHASH\n'
} > "$STATE"
touch -t 197001010000 "$F/a.md"            # old mtime; malformed hash must still trigger
PLAN="$(vault_index_plan "$F" "$IDX")"
plan_has "CHANGED"$'\t'"a.md" "$PLAN"

echo "PASS: vault-index-plan"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/vault-index-plan.sh`
Expected: FAIL — `scripts/lib/vault-index.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/vault-index.sh
#!/usr/bin/env bash
# vault-index.sh — coverage + two-stage (mtime then hash) freshness for INDEX files.
# Requires note-hash.sh to be sourced first.

index_state_file() {
  local idx="$1" dir base
  dir="$(dirname "$idx")"
  base="$(basename "$idx" .md)"
  printf '%s/.%s.state\n' "$dir" "$base"
}

state_last_reconciled() {
  [ -f "$1" ] || return 0
  sed -n 's/^# last_reconciled://p' "$1" | head -1
}

state_hash_for() {
  [ -f "$1" ] || return 0
  awk -F '\t' -v f="$2" '$1==f {print $2; exit}' "$1"
}

vault_index_plan() {
  local folder="$1" idx="$2"
  local state last f base stored mt cur idxbase
  state="$(index_state_file "$idx")"
  last="$(state_last_reconciled "$state")"
  idxbase="$(basename "$idx")"

  # DROP: state entries whose note no longer exists.
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r fn _h; do
      [ -z "$fn" ] && continue
      case "$fn" in \#*) continue ;; esac
      [ -f "$folder/$fn" ] || printf 'DROP\t%s\n' "$fn"
    done < "$state"
  fi

  for f in "$folder"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "$idxbase" ] && continue
    stored="$(state_hash_for "$state" "$base")"
    if [ -z "$stored" ]; then
      printf 'ADD\t%s\n' "$base"          # coverage gap — name-only, no content read
      continue
    fi
    if ! note_hash_valid "$stored"; then
      printf 'CHANGED\t%s\n' "$base"       # malformed -> forced reconcile
      continue
    fi
    mt="$(file_mtime "$f")"
    if [ -z "$last" ] || [ "$mt" -gt "$last" ]; then   # candidate by mtime / cold start
      cur="$(note_hash "$f")"
      [ "$cur" != "$stored" ] && printf 'CHANGED\t%s\n' "$base"   # confirmed by hash
    fi
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/vault-index-plan.sh`
Expected: `PASS: vault-index-plan`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/vault-index.sh tests/vault-index-plan.sh
git commit -m "feat: add index coverage + two-stage freshness planner"
```

---

### Task 3: Index apply (reconcile state, append-only INDEX)

**Files:**
- Modify: `scripts/lib/vault-index.sh` (add functions)
- Test: `tests/vault-index-apply.sh`

**Interfaces:**
- Consumes: `vault_index_plan`, `note_hash`, `now_epoch`, `index_state_file`.
- Produces:
  - `vault_index_apply <folder> <index_file>` → applies the plan to the **sidecar state only**: writes/updates `size:sha` for `ADD`/`CHANGED` files, removes `DROP` entries, restamps `# last_reconciled:<now_epoch>`. Idempotent: a second call on an unchanged folder produces no `ADD`/`CHANGED`/`DROP` in the subsequent plan. Returns (stdout) the list of `ADD` filenames so the caller (subagent) knows which notes need a human link appended to `INDEX.md`. Never rewrites `INDEX.md`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/vault-index-apply.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/vault-index.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-apply-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
F="$TMP/Decisions"; mkdir -p "$F"
IDX="$F/INDEX.md"; printf '# Decisions Index\n' > "$IDX"
IDX_BEFORE="$(cat "$IDX")"
printf 'note A\n' > "$F/a.md"
printf 'note B\n' > "$F/b.md"
STATE="$(index_state_file "$IDX")"

# Cold start: no state -> both notes are ADD.
ADDED="$(vault_index_apply "$F" "$IDX")"
grep -qxF "a.md" <<<"$ADDED" || fail "expected a.md in ADD output"
grep -qxF "b.md" <<<"$ADDED" || fail "expected b.md in ADD output"
[ -f "$STATE" ] || fail "state file not created"
grep -q '^# last_reconciled:[0-9]\+$' "$STATE" || fail "no last_reconciled stamp"
note_hash_valid "$(state_hash_for "$STATE" "a.md")" || fail "a.md hash not stored validly"

# INDEX.md must be untouched by apply (append-only is the subagent's job).
[ "$(cat "$IDX")" = "$IDX_BEFORE" ] || fail "apply must not modify INDEX.md"

# Idempotent: second apply with no changes -> empty plan, no new ADD.
sleep 1
ADDED2="$(vault_index_apply "$F" "$IDX")"
[ -z "$ADDED2" ] || fail "second apply should add nothing, got: $ADDED2"
PLAN="$(vault_index_plan "$F" "$IDX")"
[ -z "$PLAN" ] || fail "plan should be empty after apply, got: $PLAN"

# DROP: delete a note, apply -> state entry removed.
rm "$F/b.md"
vault_index_apply "$F" "$IDX" >/dev/null
[ -z "$(state_hash_for "$STATE" "b.md")" ] || fail "b.md should be dropped from state"

echo "PASS: vault-index-apply"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/vault-index-apply.sh`
Expected: FAIL — `vault_index_apply: command not found`.

- [ ] **Step 3: Write minimal implementation** (append to `scripts/lib/vault-index.sh`)

```bash
vault_index_apply() {
  local folder="$1" idx="$2"
  local state plan action fn tmp added=()
  state="$(index_state_file "$idx")"
  plan="$(vault_index_plan "$folder" "$idx")"

  tmp="$(mktemp "${TMPDIR:-/tmp}/idxstate-XXXXXX")"
  # Carry forward existing entries except those touched by the plan.
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r fn h; do
      case "$fn" in ''|\#*) continue ;; esac
      if ! grep -qF -- "	$fn" <<<"$plan"; then
        printf '%s\t%s\n' "$fn" "$h" >> "$tmp"
      fi
    done < "$state"
  fi
  # Apply plan: ADD/CHANGED -> (re)write current hash; DROP -> omit.
  while IFS=$'\t' read -r action fn; do
    [ -z "$action" ] && continue
    case "$action" in
      ADD|CHANGED) printf '%s\t%s\n' "$fn" "$(note_hash "$folder/$fn")" >> "$tmp"
                   [ "$action" = "ADD" ] && added+=("$fn") ;;
      DROP) : ;;  # already excluded above
    esac
  done <<<"$plan"

  { printf '# last_reconciled:%s\n' "$(now_epoch)"; sort "$tmp"; } > "$state"
  rm -f "$tmp"
  printf '%s\n' "${added[@]:-}" | sed '/^$/d'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/vault-index-apply.sh`
Expected: `PASS: vault-index-apply`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/vault-index.sh tests/vault-index-apply.sh
git commit -m "feat: add idempotent index reconcile (state-only, append-safe)"
```

---

### Task 4: vault-librarian subagent

**Files:**
- Create: `agents/vault-librarian.md`
- Test: `tests/vault-librarian-agent.sh` (contract/lint test — greps for required invariants)

**Interfaces:**
- Consumes: `scripts/lib/resolve-config.sh`, `scripts/lib/note-hash.sh`, `scripts/lib/vault-index.sh`; the `## Project Taxonomy` / `## Routing Rules` parsing convention from `skills/save-conversation/SKILL.md`.
- Produces: a dispatchable subagent (frontmatter `description:`) implementing QUERY, INSERT, and the health pass.

- [ ] **Step 1: Write the failing test** (lint the agent file for the load-bearing invariants the spec requires)

```bash
# tests/vault-librarian-agent.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="${ROOT_DIR}/agents/vault-librarian.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
need() { grep -qiF "$1" "$A" || fail "agent missing: $1"; }

[ -f "$A" ] || fail "agents/vault-librarian.md missing"
grep -q '^description:' "$A" || fail "missing frontmatter description"
need "resolve-config.sh"          # resolves vault dynamically
need "vault_index_apply"          # refreshes slice before answering
need "coverage"                   # coverage invariant present
need "find skill"                 # raw-text fallback to existing find
need "Pending.md"                 # low-confidence routing -> [ask]
need "dry-run"                    # destructive ops gated
need "strict_domains"             # respects allow-list
need "never"                      # has hard rules section
echo "PASS: vault-librarian-agent"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/vault-librarian-agent.sh`
Expected: FAIL — `agents/vault-librarian.md missing`.

- [ ] **Step 3: Write the agent file**

```markdown
---
description: Obsidian vault librarian. Answers index-grounded vault queries with citations and confidence, and files new information into the right folder + INDEX without back-and-forth. Maintains the markdown INDEX layer with on-demand two-stage freshness. Never moves or deletes notes without explicit user approval.
---

# Vault Librarian

You are the librarian for the user's Obsidian vault. You know everything that is
indexed, freshness-confirmed at query time, and you report indexing gaps when a
slice is incomplete. You are stateless between dispatches — the markdown INDEX
layer is your memory.

## Bootstrap (every dispatch)

```bash
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"
[ -z "$CONFIG" ] && { echo "Run /obsidian:setup first."; exit 0; }
VAULT_PATH="$(grep '^vault_path:' "$CONFIG" | sed 's/vault_path: //')"
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/note-hash.sh"
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/vault-index.sh"
```

Read `$VAULT_PATH/VAULT.md` (the map) and `$VAULT_PATH/Profile.md` (identity +
Constraints) before acting. Read the `## Project Taxonomy` and `## Routing
Rules` from `$CONFIG` exactly as `skills/save-conversation/SKILL.md` describes
(allow-list + precedence + cross-domain tiebreaker).

## Routing a topic to a slice

Map the query/content → domain folder(s) + that folder's `INDEX.md` via the
routing rules. Ambiguous / cross-domain → consult `VAULT.md` and widen. The
slice is one or two domain folders, never the whole vault.

## QUERY — "what do we know about X / where is Y / what did we decide about Z"

1. Route the question to its slice (folder + INDEX).
2. Refresh the slice: ``ADDED="$(vault_index_apply "$FOLDER" "$FOLDER/INDEX.md")"``.
   For each filename in `$ADDED`, append a human link ``- [[<title>]]`` to
   `INDEX.md` (append-only; never rewrite the file). The `ADD` set is the
   **coverage** result — these notes existed but were not indexed.
3. Read only the notes the INDEX points at for the topic.
4. **Coverage invariant:** if the slice had `ADD`/gaps you could not fully
   summarize, or the INDEX is otherwise known-incomplete, say so and lower your
   stated confidence. Never give a confident answer from a partial slice.
5. **Raw-text fallback:** if the INDEX slice yields zero candidate notes OR your
   confidence is below "medium", call the existing **find skill** for a raw-text
   sweep before answering. Do not reimplement search.
6. Return: the answer, `[[note]]` citations, a confidence word
   (high/medium/low), and any relevant `[ask]` items found in the slice.

## INSERT — "remember / file / record this"

1. Route the content to a target folder. **Always state the chosen folder.** If
   routing confidence is low, do **not** commit silently — append an
   `[ask:where should this go?]` entry to `$VAULT_PATH/Pending.md` and ask the
   user once.
2. **Dedup:** run the find skill / scan the target INDEX for near-duplicates
   (Jaccard ~0.4). If a likely duplicate exists, **surface it and ask** whether
   to append to the existing note — never silently merge.
3. Write the note using the matching template in `$VAULT_PATH/Templates/`.
   Append a link to the correct INDEX (`Decisions/INDEX.md`,
   `Artifacts/INDEX.md`, or the domain MOC). Link session notes to the daily
   note under `## Session Links`.
4. Unknown fields → `[ask]` markers in the note + entries in `Pending.md`
   (defer the question; do not interrogate the user mid-task).
5. Refresh the touched INDEX: ``vault_index_apply "$FOLDER" "$FOLDER/INDEX.md"``.
6. Return what you wrote, where, and a one-line summary.

## Health pass (only when asked)

Scan for vault-wide dangling links / orphans. For structural reorganization
(moving many files), **delegate to the `vault-organizer` subagent** — that is
its job, not yours.

## Hard Rules

- NEVER move or delete a note without a dry-run manifest AND explicit user
  approval.
- NEVER write outside the allow-listed domains when `strict_domains: true`.
- NEVER rewrite an `INDEX.md` wholesale — only append links.
- NEVER claim "everything" — your contract is "everything indexed, freshness-
  confirmed, gaps reported."
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/vault-librarian-agent.sh`
Expected: `PASS: vault-librarian-agent`

- [ ] **Step 5: Commit**

```bash
git add agents/vault-librarian.md tests/vault-librarian-agent.sh
git commit -m "feat: add vault-librarian subagent (QUERY/INSERT/health)"
```

---

### Task 5: `/obsidian:ask` entry point

**Files:**
- Create: `skills/ask/SKILL.md`
- Create: `commands/ask.md`
- Test: `tests/ask-entrypoint.sh`

**Interfaces:**
- Consumes: the `vault-librarian` agent (dispatched by name).
- Produces: a slash command `/obsidian:ask` and a skill that dispatches the subagent for QUERY (default) or INSERT (when the request is "remember/file/record this").

- [ ] **Step 1: Write the failing test**

```bash
# tests/ask-entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${ROOT_DIR}/skills/ask/SKILL.md"; C="${ROOT_DIR}/commands/ask.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$S" ] || fail "skills/ask/SKILL.md missing"
[ -f "$C" ] || fail "commands/ask.md missing"
grep -q '^name: ask$' "$S" || fail "skill name must be bare 'ask'"
grep -q '^description:' "$S" || fail "skill missing description"
grep -qiF "vault-librarian" "$S" || fail "skill must dispatch vault-librarian"
grep -qiF "vault-librarian" "$C" || fail "command must reference vault-librarian"
echo "PASS: ask-entrypoint"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/ask-entrypoint.sh`
Expected: FAIL — `skills/ask/SKILL.md missing`.

- [ ] **Step 3: Write the skill + command**

```markdown
<!-- skills/ask/SKILL.md -->
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
```

```markdown
<!-- commands/ask.md -->
---
description: Ask the Obsidian vault librarian (query or file info). Usage: /obsidian:ask <question or note>
---

Dispatch the `vault-librarian` subagent to handle: $ARGUMENTS

Default to QUERY. If the text asks to store/remember/file/record something, use
INSERT. Relay the subagent's cited answer (QUERY) or write summary (INSERT).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/ask-entrypoint.sh`
Expected: `PASS: ask-entrypoint`

- [ ] **Step 5: Commit**

```bash
git add skills/ask/SKILL.md commands/ask.md tests/ask-entrypoint.sh
git commit -m "feat: add /obsidian:ask entry point for the vault librarian"
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (add `/obsidian:ask` to the Skills table; add a "Vault Librarian" subsection; note the sidecar `.state` convention)
- Modify: `obsidian.local.md.example` (document that the librarian maintains INDEX files + sidecar state; no new config keys required)

**Interfaces:**
- Consumes: nothing.
- Produces: user-facing docs (README is required per repo policy).

- [ ] **Step 1: Add the skill row to the README Skills table**

In `README.md`, under the `## Skills` table, add:

```markdown
| `/obsidian:ask` | Ask the vault librarian — index-grounded answers with citations, or file new info without back-and-forth. |
```

- [ ] **Step 2: Add the Vault Librarian section to the README**

After the Skills table, add:

```markdown
### Vault Librarian

`/obsidian:ask` dispatches the `vault-librarian` subagent. It answers queries by
routing to the relevant domain folder, refreshing that slice's `INDEX.md`
on-demand (two-stage: file mtime narrows candidates, a stored `size:sha256`
content hash confirms real changes — so a Syncthing mtime-bump doesn't trigger
re-indexing), then reading only the indexed notes and citing them with a
confidence level. It reports indexing gaps rather than answering from a partial
slice, and falls back to the `find` skill for raw-text search when the index
misses.

For inserts it routes new notes through the taxonomy, dedups against existing
notes, writes via the matching `Templates/` file, and appends a link to the
right INDEX — deferring genuine unknowns to `[ask]` markers in `Pending.md`
instead of interrupting you.

Per-INDEX machine state (content hashes + last-reconciled timestamp) lives in a
hidden `.<index>.state` sidecar file beside each `INDEX.md`, so the human-
readable index is only ever appended to, never rewritten.
```

- [ ] **Step 3: Update the config example**

In `obsidian.local.md.example`, add a comment near the taxonomy section:

```markdown
# The vault-librarian subagent (/obsidian:ask) maintains an INDEX.md per indexed
# domain folder plus a hidden .<index>.state sidecar (content hashes +
# last_reconciled). No additional config keys are required — it reuses the
# Project Taxonomy and Routing Rules above.
```

- [ ] **Step 4: Verify docs reference real commands**

Run: `grep -c "/obsidian:ask" README.md`
Expected: `2` (table row + section heading reference).

- [ ] **Step 5: Commit**

```bash
git add README.md obsidian.local.md.example
git commit -m "docs: document /obsidian:ask vault librarian"
```

---

## Self-Review

**Spec coverage:**
- QUERY (route → refresh → coverage invariant → narrow → find-fallback → cited answer) → Task 2 (coverage/freshness math), Task 4 (agent QUERY section).
- INSERT (route + report folder, dedup-surface, template, INDEX append, `[ask]`/Pending, dry-run on destructive) → Task 4 (agent INSERT + Hard Rules).
- Two-stage freshness (mtime candidate + content-hash confirm; cold start; malformed → reconcile) → Tasks 1–3 with explicit fixtures (Syncthing mtime-bump, body-edit-only, cold start, malformed hash).
- Coverage = name-only set-diff (no content reads) → Task 2 `ADD` path (no `note_hash` call for coverage detection).
- One parse-validated hash scheme `size:sha256` → Task 1 `note_hash_valid` + Global Constraints.
- Append-only INDEX / state sidecar → Task 3 (apply touches state only; test asserts `INDEX.md` unchanged).
- `find` fallback as strict DAG; boundaries vs find/recall → Task 4 QUERY step 5 + README section.
- Health pass delegates to `vault-organizer` → Task 4 health section.
- Entry point `/obsidian:ask` → Task 5.
- YAGNI exclusions (no embeddings/corpus/hooks/scheduled rebuild) → nothing in the plan adds them.
- README required → Task 6.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test shows real assertions and expected output.

**Type/name consistency:** `note_hash`, `note_hash_valid`, `file_mtime`, `now_epoch` (Task 1) used identically in Tasks 2–3. `index_state_file`, `state_last_reconciled`, `state_hash_for`, `vault_index_plan` (Task 2) consumed unchanged by `vault_index_apply` (Task 3) and the agent (Task 4). ACTION tokens `ADD`/`CHANGED`/`DROP` consistent across plan output, apply input, and tests. Sidecar path `.<base>.state` consistent (Task 2 test asserts `.INDEX.state`).
