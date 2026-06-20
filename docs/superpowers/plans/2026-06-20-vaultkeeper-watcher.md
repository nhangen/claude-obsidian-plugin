# vaultkeeper Watcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the on-demand `vault-librarian` (merged PR #16) into a *watcher* — a deterministic shell substrate that runs on a tick on every keeper host, validates frontmatter, surfaces vault gaps, and stays conflict-safe over Syncthing — with the agent retained as the on-demand judgment layer.

**Architecture:** Two layers. A deterministic shell substrate (no LLM per tick) parses/validates frontmatter against a configured schema, computes surfacing candidates (frontmatter gaps, unfiled notes, open `[ask]`s, cluster candidates), maintains write-only `.base` views, and carries write-safety (advisory lease + deterministic host election + quarantine-never-delete). A `vaultkeeper-tick.sh` entrypoint orchestrates the substrate; cron (ML-1) / launchd (MBP) fire it. The agent layer (existing `vault-librarian.md`, `/obsidian:ask`) reads the same substrate on demand and adds query routing + management judgment.

**Tech Stack:** Bash (portable macOS + Linux), the existing `scripts/lib/*.sh` helpers, standalone bash test scripts in `tests/`. No new runtime dependencies.

## Global Constraints

- **No keeper code path ever *reads* a `.base` file to produce an answer.** `.base` files are write-only artifacts maintained for the human's in-Obsidian view; the headless reader is the frontmatter walk / `find-notes`. (Spec follow-up #1.)
- **Frontmatter-schema derivation is a one-time config-seeding step**, not tick logic. The tick only *validates* against the configured `frontmatter_required:` set. (Spec follow-up #3.)
- **The tick never auto-writes frontmatter.** Filling a gap is agent-judgment (on-demand, user-visible). The tick only *surfaces* gaps.
- **State (`.state`, snapshots, `last_scan`) lives under `${XDG_CACHE_HOME:-$HOME/.cache}/vaultkeeper/<vault-id>/`** — never in the synced vault.
- **Keeper-owned shared writes are only:** `_vaultkeeper.base`, `Librarian.md`, `Pending.md`. User notes and frontmatter are never keeper-gated.
- **`Librarian.md` is machine-owned**, regenerated each scan, written atomically (temp-in-same-dir then `mv`). Hand-added lines must not survive a scan.
- **`Pending.md` appends are transition-gated**: only candidates *new* since the prior-scan snapshot append as `- [ ]` lines. Cold cache (no snapshot) appends nothing.
- **Election runs in the shell substrate (pre-LLM)**, deterministically, over the live host-claim set. The non-owner defers all shared writes. Quarantine of `.sync-conflict-*` never deletes.
- **Watcher schedulers are namespaced `com.nhangen.obsidian-vaultkeeper`** and documented in the README so a host cron/launchd audit surfaces them.
- **No CEO writes.** The keeper writes only the Obsidian vault. (It is not a CEO playbook.)
- Portability: every `stat`/hash/`date` use must work on both macOS (BSD) and Linux (GNU). Follow the sequential-empty-check pattern in `scripts/lib/note-hash.sh` (`sha256_of`) — never a chained `if command -v` tool fallback.
- **bash 3.2 floor:** the macOS/MacBook keeper host ships GNU bash 3.2, which rejects `declare -A`. Use NO associative arrays anywhere; count/group with `sort | uniq -c` pipelines (the existing `scripts/lib/` uses zero assoc arrays).
- Plugin version is `1.8.0` (`.claude-plugin/plugin.json`); bump to `1.9.0` only in the final docs task.

## File Structure

**New substrate libs (`scripts/lib/`):**
- `frontmatter.sh` — parse top-level frontmatter keys; report missing required keys.
- `keeper-state.sh` — vault-id, cache dir, prior-scan snapshot, `last_scan`, cold-start detection, staleness banner.
- `vault-scan.sh` — surfacing-candidate computation (frontmatter gaps, unfiled, open `[ask]`, clusters). `.md` only; excludes `.obsidian/`, `.trash/`, `.git/`, quarantine.
- `base-views.sh` — write-only, idempotent `.base` view maintenance.
- `keeper-lease.sh` — advisory claim files, deterministic host election, quarantine-never-delete.
- `surfacing.sh` — atomic `Librarian.md` digest write; transition-gated `Pending.md` append.

**New entrypoints / installers (`scripts/`):**
- `vaultkeeper-tick.sh` — orchestrates the substrate for one tick.
- `seed-frontmatter-schema.sh` — one-time: derive dominant keys, seed `frontmatter_required:` into config.
- `install-watcher.sh` — render/install cron (Linux) or launchd (macOS), namespaced.

**Tests (`tests/`):** one standalone bash script per lib/entrypoint, plus `tests/run-all.sh`.

**Modified:** `agents/vault-librarian.md`, `commands/ask.md`, `skills/ask/SKILL.md`, `obsidian.local.md.example`, `README.md`, `.claude-plugin/plugin.json`.

**Test convention (follow existing `tests/vault-index-plan.sh`):**
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/<lib>.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/<name>-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
# ... fixtures + assertions ...
echo "PASS: <name>"
```

---

### Task 1: keeper-state.sh — cache dir, snapshot, last_scan, staleness

**Files:**
- Create: `scripts/lib/keeper-state.sh`
- Test: `tests/keeper-state.sh`

**Interfaces:**
- Consumes: `now_epoch` from `scripts/lib/note-hash.sh`.
- Produces:
  - `keeper_vault_id <vault_path>` → 16-hex-char stable id (stdout)
  - `keeper_cache_dir <vault_path>` → `${XDG_CACHE_HOME:-$HOME/.cache}/vaultkeeper/<id>` (stdout)
  - `keeper_state_init <vault_path>` → mkdir -p cache dir, prints it
  - `keeper_snapshot_file <vault_path>` → `<cache>/candidates.snapshot`
  - `keeper_has_snapshot <vault_path>` → exit 0 if snapshot exists (cold-start = non-zero)
  - `keeper_read_snapshot <vault_path>` → snapshot contents (empty if none)
  - `keeper_write_snapshot <vault_path>` → reads stdin, sorts -u, atomic write to snapshot
  - `keeper_record_scan <vault_path>` → write `now_epoch` to `<cache>/last_scan`
  - `keeper_last_scan <vault_path>` → epoch of last scan (empty if none)
  - `staleness_banner <vault_path> <interval_secs>` → prints `⚠ index last maintained <N>s ago` only if `now - last_scan > 2*interval`

- [ ] **Step 1: Write the failing test**

Create `tests/keeper-state.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-state-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
VAULT="$TMP/vault"; mkdir -p "$VAULT"

# vault-id is stable and 16 hex chars
ID1="$(keeper_vault_id "$VAULT")"
ID2="$(keeper_vault_id "$VAULT")"
[ "$ID1" = "$ID2" ] || fail "vault id not stable"
[[ "$ID1" =~ ^[0-9a-f]{16}$ ]] || fail "vault id not 16 hex: $ID1"

# cache dir is under XDG_CACHE_HOME, NOT under the vault (state-not-in-vault invariant)
CDIR="$(keeper_cache_dir "$VAULT")"
case "$CDIR" in "$XDG_CACHE_HOME"/vaultkeeper/*) : ;; *) fail "cache dir wrong: $CDIR" ;; esac
case "$CDIR" in "$VAULT"/*) fail "cache dir is inside vault: $CDIR" ;; esac

keeper_state_init "$VAULT" >/dev/null
[ -d "$CDIR" ] || fail "state_init did not create cache dir"

# cold start: no snapshot
keeper_has_snapshot "$VAULT" && fail "snapshot should not exist yet"
[ -z "$(keeper_read_snapshot "$VAULT")" ] || fail "cold read should be empty"

# write + read snapshot (sorted, deduped)
printf 'b\na\na\n' | keeper_write_snapshot "$VAULT"
keeper_has_snapshot "$VAULT" || fail "snapshot should exist after write"
[ "$(keeper_read_snapshot "$VAULT")" = "$(printf 'a\nb')" ] || fail "snapshot not sorted/deduped"

# last_scan + staleness
[ -z "$(keeper_last_scan "$VAULT")" ] || fail "last_scan should be empty"
[ -z "$(staleness_banner "$VAULT" 900)" ] || fail "no banner when last_scan absent"
keeper_record_scan "$VAULT"
[ -n "$(keeper_last_scan "$VAULT")" ] || fail "last_scan not recorded"
[ -z "$(staleness_banner "$VAULT" 900)" ] || fail "fresh scan should not warn"
# force stale: last_scan far in the past (> 2*interval)
printf '1000\n' > "$(keeper_cache_dir "$VAULT")/last_scan"
[ -n "$(staleness_banner "$VAULT" 900)" ] || fail "stale scan should warn"

echo "PASS: keeper-state"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/keeper-state.sh`
Expected: FAIL (e.g. `keeper_vault_id: command not found` or assertion failure).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/keeper-state.sh`:
```bash
#!/usr/bin/env bash
# keeper-state.sh — non-synced per-host state: cache dir, prior-scan snapshot,
# last_scan, cold-start detection, staleness banner. Requires note-hash.sh.

keeper_vault_id() {
  local out
  out="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  if [ -z "$out" ]; then
    out="$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${out:0:16}"
}

keeper_cache_dir() {
  printf '%s/vaultkeeper/%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}" "$(keeper_vault_id "$1")"
}

keeper_state_init() {
  local d; d="$(keeper_cache_dir "$1")"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

keeper_snapshot_file() { printf '%s/candidates.snapshot\n' "$(keeper_cache_dir "$1")"; }
keeper_has_snapshot()  { [ -f "$(keeper_snapshot_file "$1")" ]; }
keeper_read_snapshot() { local f; f="$(keeper_snapshot_file "$1")"; [ -f "$f" ] && cat "$f" || true; }

keeper_write_snapshot() {
  local f tmp; f="$(keeper_snapshot_file "$1")"
  mkdir -p "$(dirname "$f")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/snap-XXXXXX")" || return 1
  sort -u > "$tmp"
  mv "$tmp" "$f"
}

keeper_last_scan_file() { printf '%s/last_scan\n' "$(keeper_cache_dir "$1")"; }
keeper_record_scan()    { local f; f="$(keeper_last_scan_file "$1")"; mkdir -p "$(dirname "$f")"; now_epoch > "$f"; }
keeper_last_scan()      { local f; f="$(keeper_last_scan_file "$1")"; [ -f "$f" ] && cat "$f" || true; }

staleness_banner() {
  local vault="$1" interval="$2" last now
  last="$(keeper_last_scan "$vault")"
  [ -z "$last" ] && return 0
  now="$(now_epoch)"
  if [ "$(( now - last ))" -gt "$(( interval * 2 ))" ]; then
    printf '⚠ index last maintained %ss ago\n' "$(( now - last ))"
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/keeper-state.sh`
Expected: `PASS: keeper-state`

- [ ] **Step 5: Commit**
```bash
git add scripts/lib/keeper-state.sh tests/keeper-state.sh
git commit -m "feat: add keeper-state substrate (cache dir, snapshot, staleness)"
```

---

### Task 2: frontmatter.sh — parse keys, report missing required keys

**Files:**
- Create: `scripts/lib/frontmatter.sh`
- Test: `tests/frontmatter.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `frontmatter_block <file>` → lines inside the leading `---`…`---` fence (empty if no fence on line 1)
  - `frontmatter_keys <file>` → top-level keys (one per line; list items / nested lines excluded)
  - `frontmatter_missing <file> <required-space-separated>` → required keys not present (one per line)

- [ ] **Step 1: Write the failing test**

Create `tests/frontmatter.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/frontmatter.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/frontmatter-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# complete note: tags + type present
cat > "$TMP/complete.md" <<'EOF'
---
date: 2026-06-20
tags: [a, b]
type: note
EOF
printf -- '---\n\nbody\n' >> "$TMP/complete.md"

# gap note: missing type
cat > "$TMP/gap.md" <<'EOF'
---
date: 2026-06-20
tags: [a]
EOF
printf -- '---\n\nbody\n' >> "$TMP/gap.md"

# no frontmatter at all
printf '# just a heading\n\nbody\n' > "$TMP/none.md"

KEYS="$(frontmatter_keys "$TMP/complete.md")"
grep -qxF tags <<<"$KEYS" || fail "complete: tags key not detected"
grep -qxF type <<<"$KEYS" || fail "complete: type key not detected"
grep -qxF date <<<"$KEYS" || fail "complete: date key not detected"
# list items must NOT be treated as keys
grep -qxF a <<<"$KEYS" && fail "list item leaked as key"

[ -z "$(frontmatter_missing "$TMP/complete.md" "tags type")" ] || fail "complete should have no missing keys"
[ "$(frontmatter_missing "$TMP/gap.md" "tags type")" = "type" ] || fail "gap should report missing type"
# no-frontmatter note is missing every required key
[ "$(frontmatter_missing "$TMP/none.md" "tags type" | sort | paste -sd, -)" = "tags,type" ] || fail "none should miss tags,type"

echo "PASS: frontmatter"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/frontmatter.sh`
Expected: FAIL with `frontmatter_keys: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/frontmatter.sh`:
```bash
#!/usr/bin/env bash
# frontmatter.sh — read top-level YAML frontmatter keys and report gaps.
# Top-level keys only: lines matching ^<key>: ... . Nested/list lines (leading
# whitespace, "- item") are intentionally ignored.

frontmatter_block() {
  awk '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm { print }
  ' "$1"
}

frontmatter_keys() {
  frontmatter_block "$1" | sed -n 's/^\([A-Za-z0-9_-]\{1,\}\):.*$/\1/p'
}

frontmatter_missing() {
  local present k
  present="$(frontmatter_keys "$1")"
  for k in $2; do
    grep -qxF "$k" <<<"$present" || printf '%s\n' "$k"
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/frontmatter.sh`
Expected: `PASS: frontmatter`

- [ ] **Step 5: Commit**
```bash
git add scripts/lib/frontmatter.sh tests/frontmatter.sh
git commit -m "feat: add frontmatter key parsing + required-key validation"
```

---

### Task 3: seed-frontmatter-schema.sh — one-time schema config seeding

**Files:**
- Create: `scripts/seed-frontmatter-schema.sh`
- Test: `tests/seed-frontmatter-schema.sh`

**Interfaces:**
- Consumes: `frontmatter_keys` (Task 2), `resolve_obsidian_config` (`scripts/lib/resolve-config.sh`).
- Produces: a CLI `seed-frontmatter-schema.sh <vault_path> <config_file>` that derives keys present in ≥ 80% of vault `.md` notes and writes a `frontmatter_required: <keys>` line into the config frontmatter **only if absent**. Idempotent; never overwrites an existing `frontmatter_required:`. Prints the derived/preserved value.

This is config-seeding, run once at setup — NOT tick logic (Global Constraint / spec follow-up #3).

- [ ] **Step 1: Write the failing test**

Create `tests/seed-frontmatter-schema.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/seed-schema-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
VAULT="$TMP/vault"; mkdir -p "$VAULT"

mknote() { printf -- '---\n%s---\n\nbody\n' "$1" > "$VAULT/$2"; }
# 4 of 5 notes have tags+type (80%); date only in 1 (20%)
mknote $'tags: [x]\ntype: a\ndate: 1\n' n1.md
mknote $'tags: [x]\ntype: a\n'          n2.md
mknote $'tags: [x]\ntype: a\n'          n3.md
mknote $'tags: [x]\ntype: a\n'          n4.md
mknote $'title: x\n'                    n5.md

CFG="$TMP/obsidian.local.md"
printf -- '---\nvault_path: %s\n---\n' "$VAULT" > "$CFG"

OUT="$(bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG")"
grep -q '^frontmatter_required:' "$CFG" || fail "config not seeded"
SEEDED="$(grep '^frontmatter_required:' "$CFG" | sed 's/frontmatter_required: *//')"
grep -qw tags <<<"$SEEDED" || fail "tags (80%) should be required: $SEEDED"
grep -qw type <<<"$SEEDED" || fail "type (80%) should be required: $SEEDED"
grep -qw date <<<"$SEEDED" && fail "date (20%) must NOT be required: $SEEDED"

# Idempotent: a second run must not duplicate or overwrite the existing line.
bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG" >/dev/null
[ "$(grep -c '^frontmatter_required:' "$CFG")" -eq 1 ] || fail "duplicate frontmatter_required line"

# Explicit pre-existing value is preserved, not recomputed.
CFG2="$TMP/cfg2.md"
printf -- '---\nvault_path: %s\nfrontmatter_required: project\n---\n' "$VAULT" > "$CFG2"
bash "${ROOT_DIR}/scripts/seed-frontmatter-schema.sh" "$VAULT" "$CFG2" >/dev/null
[ "$(grep '^frontmatter_required:' "$CFG2" | sed 's/.*: *//')" = "project" ] || fail "existing value overwritten"

echo "PASS: seed-frontmatter-schema"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/seed-frontmatter-schema.sh`
Expected: FAIL (`No such file or directory` for the script).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/seed-frontmatter-schema.sh`:
```bash
#!/usr/bin/env bash
# seed-frontmatter-schema.sh — ONE-TIME: derive the dominant top-level
# frontmatter keys across the vault and seed `frontmatter_required:` into the
# config, only if absent. NOT run on the tick. Idempotent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/frontmatter.sh"

VAULT="${1:?usage: seed-frontmatter-schema.sh <vault_path> <config_file>}"
CFG="${2:?usage: seed-frontmatter-schema.sh <vault_path> <config_file>}"
THRESHOLD_PCT="${SCHEMA_THRESHOLD_PCT:-80}"

if grep -q '^frontmatter_required:' "$CFG"; then
  grep '^frontmatter_required:' "$CFG" | sed 's/frontmatter_required: *//'
  exit 0
fi

# NOTE: no associative arrays — the MacBook keeper host runs bash 3.2, which
# rejects `declare -A`. Count via a sort|uniq -c pipeline (matches existing
# scripts/lib style, which uses zero assoc arrays).
find_notes() {
  find "$VAULT" -type f -name '*.md' \
    ! -path '*/.obsidian/*' ! -path '*/.trash/*' ! -path '*/.git/*'
}
total="$(find_notes | wc -l | tr -d ' ')"

required=""
if [ "$total" -gt 0 ]; then
  # Stream one line per (note, distinct key); uniq -c => count of notes per key.
  while read -r cnt key; do
    [ -z "$cnt" ] && continue
    if [ "$(( cnt * 100 / total ))" -ge "$THRESHOLD_PCT" ]; then
      required="${required:+$required }$key"
    fi
  done < <(
    find_notes | while IFS= read -r f; do frontmatter_keys "$f" | sort -u; done \
      | sort | uniq -c
  )
fi
required="$(printf '%s\n' $required | sort | paste -sd' ' -)"

# Insert into the config frontmatter (after the opening ---).
tmp="$(mktemp "${TMPDIR:-/tmp}/cfg-XXXXXX")"
awk -v line="frontmatter_required: ${required}" '
  NR==1 && $0=="---" { print; print line; inserted=1; next }
  { print }
  END { if (!inserted) print line }
' "$CFG" > "$tmp"
mv "$tmp" "$CFG"
printf '%s\n' "$required"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/seed-frontmatter-schema.sh`
Expected: `PASS: seed-frontmatter-schema`

- [ ] **Step 5: Commit**
```bash
git add scripts/seed-frontmatter-schema.sh tests/seed-frontmatter-schema.sh
git commit -m "feat: add one-time frontmatter-schema config seeding"
```

---

### Task 4: vault-scan.sh — surfacing candidate computation

**Files:**
- Create: `scripts/lib/vault-scan.sh`
- Test: `tests/vault-scan.sh`

**Interfaces:**
- Consumes: `frontmatter_missing` (Task 2).
- Produces (all emit tab-separated candidate lines; `.md` only; exclude `.obsidian/`, `.trash/`, `.git/`, `.vaultkeeper-quarantine/`):
  - `scan_frontmatter_gaps <vault_path> <required-space-separated>` → `GAP\t<relpath>\t<missing,csv>`
  - `scan_unfiled <vault_path>` → `UNFILED\t<relpath>` for every `.md` under `Inbox/`
  - `scan_open_asks <vault_path>` → `ASK\t<relpath>` for every note containing a `[ask` marker
  - `scan_clusters <vault_path> <threshold>` → `CLUSTER\t<folder-relpath>\t<stem>\t<count>` when ≥ threshold distinct files in a folder share a slug token (numeric and single-char tokens dropped)

Note: no function reads `.base` (Global Constraint). `.base` files are not `*.md` so the `find` filters already exclude them.

- [ ] **Step 1: Write the failing test**

Create `tests/vault-scan.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/frontmatter.sh"
. "${ROOT_DIR}/scripts/lib/vault-scan.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
has() { grep -qF "$1" <<<"$2" || fail "expected: $1"$'\n'"in:"$'\n'"$2"; }
lacks() { grep -qF "$1" <<<"$2" && fail "did NOT expect: $1"; return 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-scan-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
V="$TMP/vault"; mkdir -p "$V/Inbox" "$V/Projects" "$V/.obsidian" "$V/.trash"

note() { printf -- '---\n%s---\n\n%s\n' "$1" "$2" > "$V/$3"; }
note $'tags: [x]\ntype: a\n' 'clean'                  "Projects/good.md"
note $'tags: [x]\n'          'missing type'           "Projects/gap.md"
note ''                      'has [ask:where?] marker' "Projects/asky.md"
printf 'loose inbox note\n'  > "$V/Inbox/unfiled.md"
# excluded dirs must be ignored
note $'\n' 'x' ".obsidian/cfg.md"
note $'\n' 'x' ".trash/old.md"
# a .base file present — must never appear in any scan output
printf 'filters: {}\n' > "$V/_vaultkeeper.base"
# cluster: 3 files sharing token "weekly" in Projects/
printf 'a\n' > "$V/Projects/weekly-review-1.md"
printf 'a\n' > "$V/Projects/weekly-review-2.md"
printf 'a\n' > "$V/Projects/weekly-sync-3.md"

GAPS="$(scan_frontmatter_gaps "$V" "tags type")"
has  "GAP"$'\t'"Projects/gap.md"$'\t'"type" "$GAPS"
lacks "GAP"$'\t'"Projects/good.md" "$GAPS"
lacks ".obsidian" "$GAPS"
lacks ".trash" "$GAPS"
lacks ".base" "$GAPS"

UNFILED="$(scan_unfiled "$V")"
has "UNFILED"$'\t'"Inbox/unfiled.md" "$UNFILED"

ASKS="$(scan_open_asks "$V")"
has "ASK"$'\t'"Projects/asky.md" "$ASKS"
lacks "ASK"$'\t'"Projects/good.md" "$ASKS"

CLUSTERS="$(scan_clusters "$V" 3)"
# "weekly" appears in 3 distinct files in Projects/ -> emitted with count 3.
has "CLUSTER"$'\t'"Projects"$'\t'"weekly"$'\t'"3" "$CLUSTERS"
# "review" appears in only 2 files (below threshold 3) -> must NOT be emitted.
lacks "CLUSTER"$'\t'"Projects"$'\t'"review" "$CLUSTERS"
grep -q '\.base' <<<"$CLUSTERS" && fail ".base leaked into clusters"

echo "PASS: vault-scan"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/vault-scan.sh`
Expected: FAIL with `scan_frontmatter_gaps: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/vault-scan.sh`:
```bash
#!/usr/bin/env bash
# vault-scan.sh — compute surfacing candidates from the vault. .md only;
# excludes .obsidian/, .trash/, .git/, .vaultkeeper-quarantine/. Never reads
# .base files (they are not .md, so the find filters exclude them).
# Requires frontmatter.sh.

_scan_find_md() {
  find "$1" -type f -name '*.md' \
    ! -path '*/.obsidian/*' ! -path '*/.trash/*' \
    ! -path '*/.git/*' ! -path '*/.vaultkeeper-quarantine/*'
}

scan_frontmatter_gaps() {
  local vault="$1" required="$2" f miss
  while IFS= read -r f; do
    miss="$(frontmatter_missing "$f" "$required" | sort | paste -sd, -)"
    [ -n "$miss" ] && printf 'GAP\t%s\t%s\n' "${f#"$vault"/}" "$miss"
  done < <(_scan_find_md "$vault")
}

scan_unfiled() {
  local vault="$1" f
  [ -d "$vault/Inbox" ] || return 0
  while IFS= read -r f; do
    printf 'UNFILED\t%s\n' "${f#"$vault"/}"
  done < <(find "$vault/Inbox" -type f -name '*.md')
}

scan_open_asks() {
  local vault="$1" f
  while IFS= read -r f; do
    if grep -qI '\[ask' "$f" 2>/dev/null; then
      printf 'ASK\t%s\n' "${f#"$vault"/}"
    fi
  done < <(_scan_find_md "$vault")
}

# Cluster: per immediate subfolder, count distinct files containing each slug
# token (drop purely-numeric and single-char tokens). Emit tokens shared by
# >= threshold distinct files. No associative arrays (bash 3.2 on the macOS
# keeper host) — count via sort|uniq -c. Tokens are unique-per-file (sort -u),
# so uniq -c across files = number of distinct files sharing the token.
scan_clusters() {
  local vault="$1" threshold="$2" dir base f tok cnt
  while IFS= read -r dir; do
    while read -r cnt tok; do
      [ -z "$cnt" ] && continue
      [ "$cnt" -ge "$threshold" ] \
        && printf 'CLUSTER\t%s\t%s\t%s\n' "${dir#"$vault"/}" "$tok" "$cnt"
    done < <(
      while IFS= read -r f; do
        base="$(basename "$f" .md)"
        for tok in $(printf '%s\n' "$base" | tr '-' '\n' | sort -u); do
          case "$tok" in
            ''|*[!0-9]* ) ;;   # keep: not purely numeric
            * ) continue ;;    # drop: purely numeric
          esac
          [ "${#tok}" -le 1 ] && continue
          printf '%s\n' "$tok"
        done
      done < <(find "$dir" -maxdepth 1 -type f -name '*.md') \
        | sort | uniq -c
    )
  done < <(find "$vault" -type d \
            ! -path '*/.obsidian' ! -path '*/.obsidian/*' \
            ! -path '*/.trash'    ! -path '*/.trash/*' \
            ! -path '*/.git'      ! -path '*/.git/*' \
            ! -path '*/.vaultkeeper-quarantine' ! -path '*/.vaultkeeper-quarantine/*')
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/vault-scan.sh`
Expected: `PASS: vault-scan`

- [ ] **Step 5: Commit**
```bash
git add scripts/lib/vault-scan.sh tests/vault-scan.sh
git commit -m "feat: add vault-scan surfacing candidates (gaps, unfiled, asks, clusters)"
```

---

### Task 5: base-views.sh — write-only, idempotent `.base` maintenance

**Files:**
- Create: `scripts/lib/base-views.sh`
- Test: `tests/base-views.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `base_view_content` → canonical `.base` YAML for the frontmatter-gaps view (stdout)
  - `base_view_write <target.base>` → write the canonical content only if it differs from the target (idempotent; no-op + unchanged mtime when content matches)

This file only ever **writes** `.base` content. No counterpart reader exists (Global Constraint / follow-up #1).

- [ ] **Step 1: Write the failing test**

Create `tests/base-views.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/base-views.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/base-views-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
T="$TMP/_vaultkeeper.base"

base_view_write "$T"
[ -f "$T" ] || fail "base file not created"
H1="$(note_hash "$T")"

# Idempotent: a second write with identical content must not rewrite the file.
MT1="$(file_mtime "$T")"
sleep 1
base_view_write "$T"
MT2="$(file_mtime "$T")"
[ "$MT1" = "$MT2" ] || fail "idempotent write changed mtime (rewrote unchanged file)"
[ "$(note_hash "$T")" = "$H1" ] || fail "content changed on idempotent write"

# Drift: external edit is corrected on next write.
printf 'tampered\n' > "$T"
base_view_write "$T"
[ "$(note_hash "$T")" = "$H1" ] || fail "drift not corrected"

echo "PASS: base-views"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/base-views.sh`
Expected: FAIL with `base_view_write: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/base-views.sh`:
```bash
#!/usr/bin/env bash
# base-views.sh — maintain the write-only Obsidian Bases view that renders
# frontmatter gaps inside the GUI. WRITE-ONLY: no keeper code reads a .base to
# answer a query (headless reader is the frontmatter walk). Idempotent.

base_view_content() {
  cat <<'EOF'
filters:
  or:
    - '!file.hasProperty("tags")'
    - '!file.hasProperty("type")'
views:
  - type: table
    name: Frontmatter gaps
    order:
      - file.name
      - file.folder
EOF
}

base_view_write() {
  local target="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/base-XXXXXX")" || return 1
  base_view_content > "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$target"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/base-views.sh`
Expected: `PASS: base-views`

- [ ] **Step 5: Commit**
```bash
git add scripts/lib/base-views.sh tests/base-views.sh
git commit -m "feat: add write-only idempotent .base view maintenance"
```

---

### Task 6: keeper-lease.sh — advisory lease, deterministic election, quarantine

**Files:**
- Create: `scripts/lib/keeper-lease.sh`
- Test: `tests/keeper-lease.sh`

**Interfaces:**
- Consumes: `now_epoch` (note-hash.sh).
- Produces:
  - `keeper_claim_path <lease_dir> <host>` → `<lease_dir>/.keeper-claim-<host>`
  - `keeper_claim_write <lease_dir> <host>` → mkdir lease dir, write `now_epoch` into this host's claim
  - `keeper_live_hosts <lease_dir> [max_age_secs]` → hosts with a claim (filtered by age if max_age given)
  - `keeper_elect <lease_dir> <priority_csv> [max_age_secs]` → the single owner host (priority list first, then lexicographically lowest live host)
  - `keeper_is_owner <lease_dir> <this_host> <priority_csv> [max_age_secs]` → exit 0 iff this host is the elected owner
  - `keeper_quarantine_conflicts <vault_path>` → move every `.sync-conflict-*` of a keeper-owned file (`Librarian.md*`, `Pending.md*`, `*.base*`) into `<vault>/.vaultkeeper-quarantine/<epoch>-<name>`, never delete; emit `QUARANTINE\t<relpath>` per move

- [ ] **Step 1: Write the failing test**

Create `tests/keeper-lease.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-lease.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-lease-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
L="$TMP/.vaultkeeper"

# Two fully-synced claims; priority ml-1 > mbp -> ml-1 owns, deterministically
# from BOTH hosts' point of view (same claim set => same owner).
keeper_claim_write "$L" "ml-1"
keeper_claim_write "$L" "mbp"
[ "$(keeper_elect "$L" "ml-1,mbp")" = "ml-1" ] || fail "ml-1 should win by priority"
keeper_is_owner "$L" "ml-1" "ml-1,mbp" || fail "ml-1 should be owner"
keeper_is_owner "$L" "mbp"  "ml-1,mbp" && fail "mbp must NOT be owner (defers)"

# Partially-propagated claim set (follow-up #2): ml-1's claim has NOT yet synced
# to this host; only mbp and mac-2 are visible. Election must still be
# deterministic over the present set, and the loser writes nothing.
L2="$TMP/.vk2"
keeper_claim_write "$L2" "mbp"
keeper_claim_write "$L2" "mac-2"
OWNER="$(keeper_elect "$L2" "ml-1,mbp")"   # ml-1 absent -> highest present priority = mbp
[ "$OWNER" = "mbp" ] || fail "with ml-1 absent, mbp should own present set: $OWNER"
keeper_is_owner "$L2" "mac-2" "ml-1,mbp" && fail "mac-2 must defer in partial set"

# No priority list: lexicographically lowest live host wins (still deterministic).
L3="$TMP/.vk3"
keeper_claim_write "$L3" "zeta"
keeper_claim_write "$L3" "alpha"
[ "$(keeper_elect "$L3" "")" = "alpha" ] || fail "lexicographic fallback should pick alpha"

# Stale claim is ignored when max_age is given.
L4="$TMP/.vk4"; mkdir -p "$L4"
printf '1000\n' > "$L4/.keeper-claim-old"        # ancient
keeper_claim_write "$L4" "fresh"
[ "$(keeper_elect "$L4" "" 86400)" = "fresh" ] || fail "stale claim should be excluded"

# Quarantine: a planted .sync-conflict on Librarian.md is moved aside, surfaced,
# and NEVER deleted.
V="$TMP/vault"; mkdir -p "$V"
printf 'digest\n' > "$V/Librarian.md"
CONFLICT="$V/Librarian.sync-conflict-20260620-120000-ABCDEFG.md"
printf 'conflicted copy\n' > "$CONFLICT"
OUT="$(keeper_quarantine_conflicts "$V")"
grep -q "QUARANTINE"$'\t'"Librarian.sync-conflict" <<<"$OUT" || fail "conflict not surfaced"
[ ! -e "$CONFLICT" ] || fail "conflict not moved out of vault root"
[ "$(find "$V/.vaultkeeper-quarantine" -name '*Librarian.sync-conflict*' | wc -l | tr -d ' ')" = "1" ] \
  || fail "conflict not preserved in quarantine (data loss)"
[ -f "$V/Librarian.md" ] || fail "canonical Librarian.md must be untouched"

echo "PASS: keeper-lease"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/keeper-lease.sh`
Expected: FAIL with `keeper_claim_write: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/keeper-lease.sh`:
```bash
#!/usr/bin/env bash
# keeper-lease.sh — advisory lease (claim files), deterministic host election
# (pre-LLM), and quarantine-never-delete for .sync-conflict-* of keeper-owned
# files. The lease is NOT a lock; correctness rests on election + quarantine.
# Requires note-hash.sh (now_epoch).

keeper_claim_path()  { printf '%s/.keeper-claim-%s\n' "$1" "$2"; }

keeper_claim_write() {
  mkdir -p "$1"
  now_epoch > "$(keeper_claim_path "$1" "$2")"
}

keeper_live_hosts() {
  local dir="$1" max_age="${2:-}" now c host ts
  now="$(now_epoch)"
  for c in "$dir"/.keeper-claim-*; do
    [ -e "$c" ] || continue
    host="${c##*/.keeper-claim-}"
    if [ -n "$max_age" ]; then
      ts="$(cat "$c" 2>/dev/null)"
      [ -n "$ts" ] || continue
      [ "$(( now - ts ))" -le "$max_age" ] || continue
    fi
    printf '%s\n' "$host"
  done
}

keeper_elect() {
  local dir="$1" prio_csv="${2:-}" max_age="${3:-}" hosts h
  hosts="$(keeper_live_hosts "$dir" "$max_age")"
  [ -z "$hosts" ] && return 0
  if [ -n "$prio_csv" ]; then
    local IFS=','
    for h in $prio_csv; do
      [ -z "$h" ] && continue
      if grep -qxF "$h" <<<"$hosts"; then
        printf '%s\n' "$h"
        return 0
      fi
    done
  fi
  printf '%s\n' "$hosts" | LC_ALL=C sort | head -1
}

keeper_is_owner() {
  local owner
  owner="$(keeper_elect "$1" "${3:-}" "${4:-}")"
  [ -n "$owner" ] && [ "$owner" = "$2" ]
}

keeper_quarantine_conflicts() {
  local vault="$1" q="$1/.vaultkeeper-quarantine" c base
  while IFS= read -r c; do
    base="$(basename "$c")"
    case "$base" in
      Librarian.sync-conflict-*|Pending.sync-conflict-*|*.base.sync-conflict-*|*.sync-conflict-*.base)
        mkdir -p "$q"
        mv "$c" "$q/$(now_epoch)-$base"
        printf 'QUARANTINE\t%s\n' "${c#"$vault"/}" ;;
      *) : ;;   # not a keeper-owned conflict — leave it for the user
    esac
  done < <(find "$vault" -maxdepth 2 -type f -name '*.sync-conflict-*' \
            ! -path '*/.vaultkeeper-quarantine/*' 2>/dev/null)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/keeper-lease.sh`
Expected: `PASS: keeper-lease`

- [ ] **Step 5: Commit**
```bash
git add scripts/lib/keeper-lease.sh tests/keeper-lease.sh
git commit -m "feat: add advisory lease, deterministic election, conflict quarantine"
```

---

### Task 7: surfacing.sh — atomic Librarian.md digest + transition-gated Pending.md

**Files:**
- Create: `scripts/lib/surfacing.sh`
- Test: `tests/surfacing.sh`

**Interfaces:**
- Consumes: `now_epoch` (note-hash.sh); `keeper_has_snapshot`, `keeper_read_snapshot`, `keeper_write_snapshot` (keeper-state.sh, Task 1).
- Produces:
  - `surfacing_digest <vault_path>` → reads candidate lines on stdin; writes `<vault>/Librarian.md` atomically (temp in same dir then `mv`), machine-owned header, counts per category.
  - `surfacing_pending_transition <vault_path>` → reads candidate lines on stdin; on cold cache (no snapshot) writes the snapshot and appends nothing to `Pending.md`; otherwise appends one `- [ ] <kind>: <rest>` line per candidate **new since the snapshot**, then rewrites the snapshot to current.

- [ ] **Step 1: Write the failing test**

Create `tests/surfacing.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
. "${ROOT_DIR}/scripts/lib/surfacing.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/surfacing-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
V="$TMP/vault"; mkdir -p "$V"; keeper_state_init "$V" >/dev/null

C1=$'GAP\tProjects/gap.md\ttype\nUNFILED\tInbox/x.md'

# --- Librarian.md: atomic, machine-owned, regenerated ---
printf '%s\n' "$C1" | surfacing_digest "$V"
[ -f "$V/Librarian.md" ] || fail "Librarian.md not written"
grep -q 'MACHINE-OWNED' "$V/Librarian.md" || fail "missing machine-owned header"
grep -q 'Projects/gap.md' "$V/Librarian.md" || fail "gap not in digest"
# hand-added line must NOT survive the next scan (full overwrite)
printf '\nHAND EDIT\n' >> "$V/Librarian.md"
printf '%s\n' "$C1" | surfacing_digest "$V"
grep -q 'HAND EDIT' "$V/Librarian.md" && fail "hand edit survived (not machine-owned)"

# --- Pending.md transition gating ---
# scan 1 = cold cache: snapshot written, Pending untouched
printf '%s\n' "$C1" | surfacing_pending_transition "$V"
[ ! -f "$V/Pending.md" ] || [ "$(grep -c '^- \[ \]' "$V/Pending.md")" -eq 0 ] \
  || fail "cold start must not append to Pending"
keeper_has_snapshot "$V" || fail "cold start must write snapshot"

# scan 2 = identical candidates: nothing new appends
printf '%s\n' "$C1" | surfacing_pending_transition "$V"
[ ! -f "$V/Pending.md" ] || [ "$(grep -c '^- \[ \]' "$V/Pending.md")" -eq 0 ] \
  || fail "unchanged scan must append nothing"

# scan 3 = one NEW candidate: exactly one line appends
C2=$'GAP\tProjects/gap.md\ttype\nUNFILED\tInbox/x.md\nASK\tProjects/new.md'
printf '%s\n' "$C2" | surfacing_pending_transition "$V"
[ "$(grep -c '^- \[ \]' "$V/Pending.md")" -eq 1 ] || fail "exactly one new item expected"
grep -q 'Projects/new.md' "$V/Pending.md" || fail "new ASK item not appended"

echo "PASS: surfacing"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/surfacing.sh`
Expected: FAIL with `surfacing_digest: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/surfacing.sh`:
```bash
#!/usr/bin/env bash
# surfacing.sh — write the machine-owned Librarian.md digest atomically, and
# append only genuinely-new candidates to Pending.md (transition-gated against
# the prior-scan snapshot). Requires note-hash.sh + keeper-state.sh.

surfacing_digest() {
  local vault="$1" lines tmp target="$1/Librarian.md" kind label
  lines="$(cat)"
  tmp="$(mktemp "$vault/.Librarian-XXXXXX")" || return 1
  {
    printf '%s\n' '<!-- MACHINE-OWNED: regenerated each vaultkeeper scan. Edits do not persist. -->'
    printf '# Librarian\n\nlast_scan: %s\n' "$(now_epoch)"
    for kind in GAP UNFILED ASK CLUSTER QUARANTINE; do
      case "$kind" in
        GAP) label="Frontmatter gaps" ;;
        UNFILED) label="Unfiled (Inbox)" ;;
        ASK) label="Open [ask] items" ;;
        CLUSTER) label="Promotable clusters" ;;
        QUARANTINE) label="Quarantined conflicts" ;;
      esac
      local sel; sel="$(grep "^${kind}"$'\t' <<<"$lines" || true)"
      printf '\n## %s (%s)\n' "$label" "$(printf '%s' "$sel" | grep -c . || true)"
      [ -n "$sel" ] && printf '%s\n' "$sel" | cut -f2- | sed 's/^/- /'
    done
  } > "$tmp"
  mv "$tmp" "$target"
}

surfacing_pending_transition() {
  local vault="$1" cur snap new pending="$1/Pending.md"
  cur="$(sort -u)"
  if ! keeper_has_snapshot "$vault"; then
    printf '%s\n' "$cur" | keeper_write_snapshot "$vault"
    return 0
  fi
  snap="$(keeper_read_snapshot "$vault")"
  new="$(comm -23 <(printf '%s\n' "$cur") <(printf '%s\n' "$snap"))"
  if [ -n "$new" ]; then
    while IFS=$'\t' read -r kind rest; do
      [ -z "$kind" ] && continue
      printf -- '- [ ] %s: %s\n' "$kind" "$rest" >> "$pending"
    done <<<"$new"
  fi
  printf '%s\n' "$cur" | keeper_write_snapshot "$vault"
}
```

Note: `comm` requires both inputs sorted. `cur` is `sort -u`; `keeper_read_snapshot` returns the snapshot which `keeper_write_snapshot` already stored `sort -u`. Both are byte-sorted under the default locale used consistently here.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/surfacing.sh`
Expected: `PASS: surfacing`

- [ ] **Step 5: Commit**
```bash
git add scripts/lib/surfacing.sh tests/surfacing.sh
git commit -m "feat: add atomic Librarian.md digest + transition-gated Pending.md"
```

---

### Task 8: vaultkeeper-tick.sh — orchestrate one substrate tick

**Files:**
- Create: `scripts/vaultkeeper-tick.sh`
- Test: `tests/vaultkeeper-tick.sh`

**Interfaces:**
- Consumes: every lib above + `resolve_obsidian_config`.
- Produces: a runnable tick. Reads config (`vault_path`, `frontmatter_required`, `keeper_host_priority`, `keeper_interval_secs`). Order: init state → write this host's claim → **ownership gate** → (owner only) quarantine → scan candidates → write `.base` → write `Librarian.md` → transition-gate `Pending.md` → record scan. Non-owner exits 0 after the gate without shared writes. Honors `VAULTKEEPER_HOST` override (for tests) instead of `hostname -s`.

- [ ] **Step 1: Write the failing test**

Create `tests/vaultkeeper-tick.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vk-tick-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
V="$TMP/vault"; mkdir -p "$V/Inbox"
printf -- '---\ntags: [x]\n---\n\nbody\n' > "$V/gap.md"   # missing type
printf 'loose\n' > "$V/Inbox/u.md"

CFG="$TMP/obsidian.local.md"
cat > "$CFG" <<EOF
---
vault_path: $V
frontmatter_required: tags type
keeper_host_priority: ml-1 mbp
keeper_interval_secs: 900
---
EOF
export OBSIDIAN_LOCAL_MD="$CFG"

run_tick() { VAULTKEEPER_HOST="$1" bash "${ROOT_DIR}/scripts/vaultkeeper-tick.sh"; }

# Owner run (this host = ml-1, top priority): full substrate runs.
run_tick "ml-1"
[ -f "$V/Librarian.md" ] || fail "owner tick did not write Librarian.md"
grep -q 'gap.md' "$V/Librarian.md" || fail "frontmatter gap not surfaced"
[ -f "$V/_vaultkeeper.base" ] || fail "owner tick did not write .base"
# state lives in cache, NOT in the vault
[ -d "$(keeper_cache_dir "$V")" ] || fail "cache dir missing"
find "$V" -name 'candidates.snapshot' | grep -q . && fail "snapshot leaked into vault"
# cold start: nothing appended to Pending yet
[ ! -f "$V/Pending.md" ] || [ "$(grep -c '^- \[ \]' "$V/Pending.md")" -eq 0 ] \
  || fail "cold-start tick must not append to Pending"

# Non-owner run: mbp is NOT owner while ml-1's claim is live -> defers, no writes.
rm -f "$V/Librarian.md"
run_tick "mbp"
[ ! -f "$V/Librarian.md" ] || fail "non-owner must not write Librarian.md"

echo "PASS: vaultkeeper-tick"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/vaultkeeper-tick.sh`
Expected: FAIL (`No such file or directory` for the tick script).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/vaultkeeper-tick.sh`:
```bash
#!/usr/bin/env bash
# vaultkeeper-tick.sh — one deterministic substrate tick (no LLM). Runs on
# cron (ML-1) / launchd (MBP). Owner-gated shared writes; quarantine + scan +
# surface only as the elected owner. State is non-synced (under XDG cache).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/frontmatter.sh"
. "${ROOT}/lib/vault-scan.sh"
. "${ROOT}/lib/base-views.sh"
. "${ROOT}/lib/keeper-state.sh"
. "${ROOT}/lib/keeper-lease.sh"
. "${ROOT}/lib/surfacing.sh"
. "${ROOT}/lib/resolve-config.sh"

CONFIG="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}")" || {
  echo "vaultkeeper: no config; run /obsidian:setup" >&2; exit 0; }

cfg_val() { grep "^$1:" "$CONFIG" | head -1 | sed "s/^$1: *//"; }
VAULT="$(cfg_val vault_path)"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || { echo "vaultkeeper: vault not found: $VAULT" >&2; exit 0; }

REQUIRED="$(cfg_val frontmatter_required)"; REQUIRED="${REQUIRED:-tags type}"
PRIORITY="$(cfg_val keeper_host_priority | tr ' ' ',')"
INTERVAL="$(cfg_val keeper_interval_secs)"; INTERVAL="${INTERVAL:-900}"
MAXAGE=$(( INTERVAL * 2 ))
HOST="${VAULTKEEPER_HOST:-$(hostname -s)}"
LEASE="$VAULT/.vaultkeeper"

keeper_state_init "$VAULT" >/dev/null
keeper_claim_write "$LEASE" "$HOST"

if ! keeper_is_owner "$LEASE" "$HOST" "$PRIORITY" "$MAXAGE"; then
  echo "vaultkeeper: $HOST defers to $(keeper_elect "$LEASE" "$PRIORITY" "$MAXAGE")" >&2
  exit 0
fi

CONFLICTS="$(keeper_quarantine_conflicts "$VAULT" || true)"
CAND="$( {
  scan_frontmatter_gaps "$VAULT" "$REQUIRED"
  scan_unfiled "$VAULT"
  scan_open_asks "$VAULT"
  scan_clusters "$VAULT" 3
  [ -n "$CONFLICTS" ] && printf '%s\n' "$CONFLICTS"
} | sed '/^$/d' )"

base_view_write "$VAULT/_vaultkeeper.base"
printf '%s\n' "$CAND" | surfacing_digest "$VAULT"
printf '%s\n' "$CAND" | surfacing_pending_transition "$VAULT"
keeper_record_scan "$VAULT"
echo "vaultkeeper: scan complete ($HOST)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/vaultkeeper-tick.sh`
Expected: `PASS: vaultkeeper-tick`

- [ ] **Step 5: Commit**
```bash
git add scripts/vaultkeeper-tick.sh tests/vaultkeeper-tick.sh
git commit -m "feat: add owner-gated vaultkeeper substrate tick"
```

---

### Task 9: install-watcher.sh — render/install namespaced cron + launchd

**Files:**
- Create: `scripts/install-watcher.sh`
- Test: `tests/install-watcher.sh`

**Interfaces:**
- Consumes: nothing (renders text; install path uses `crontab`/`launchctl`).
- Produces a CLI with argv-validated subcommands:
  - `install-watcher.sh render-launchd <tick_abs_path> <interval_secs>` → prints a launchd plist with label `com.nhangen.obsidian-vaultkeeper`, `ProgramArguments` invoking the tick, `StartInterval` = interval.
  - `install-watcher.sh render-cron <tick_abs_path> <interval_secs>` → prints a crontab line invoking the tick, ending with the marker comment `# com.nhangen.obsidian-vaultkeeper`.
  - `install-watcher.sh install <tick_abs_path>` → on Darwin writes/loads the plist; on Linux adds the cron line (idempotent — replaces any existing namespaced line). Unknown subcommand → exit non-zero with usage.

- [ ] **Step 1: Write the failing test**

Create `tests/install-watcher.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
SH="${ROOT_DIR}/scripts/install-watcher.sh"
TICK="/abs/path/to/vaultkeeper-tick.sh"

PLIST="$(bash "$SH" render-launchd "$TICK" 900)"
grep -q 'com.nhangen.obsidian-vaultkeeper' <<<"$PLIST" || fail "plist missing namespace label"
grep -qF "$TICK" <<<"$PLIST" || fail "plist missing tick path"
grep -q '<integer>900</integer>' <<<"$PLIST" || fail "plist missing StartInterval"

CRON="$(bash "$SH" render-cron "$TICK" 900)"
grep -qF "$TICK" <<<"$CRON" || fail "cron line missing tick path"
grep -q '# com.nhangen.obsidian-vaultkeeper' <<<"$CRON" || fail "cron line missing namespace marker"

# Unknown subcommand must fail loudly (enum-config-typo-fallback discipline).
if bash "$SH" frobnicate "$TICK" 900 >/dev/null 2>&1; then
  fail "unknown subcommand should exit non-zero"
fi

echo "PASS: install-watcher"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/install-watcher.sh`
Expected: FAIL (`No such file or directory`).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/install-watcher.sh`:
```bash
#!/usr/bin/env bash
# install-watcher.sh — render or install the namespaced vaultkeeper scheduler.
# launchd on macOS, cron on Linux. Label/marker: com.nhangen.obsidian-vaultkeeper
# (documented in README so a host scheduler audit surfaces it).
set -euo pipefail
LABEL="com.nhangen.obsidian-vaultkeeper"

usage() { echo "usage: install-watcher.sh {render-launchd|render-cron|install} <tick_abs_path> [interval_secs]" >&2; exit 2; }

render_launchd() {
  local tick="$1" interval="$2"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${tick}</string>
  </array>
  <key>StartInterval</key><integer>${interval}</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
}

render_cron() {
  local tick="$1" interval="$2" minutes
  minutes=$(( interval / 60 )); [ "$minutes" -lt 1 ] && minutes=1
  printf '*/%s * * * * /bin/bash %s >/dev/null 2>&1 # %s\n' "$minutes" "$tick" "$LABEL"
}

install_watcher() {
  local tick="$1" interval="${2:-900}"
  case "$(uname -s)" in
    Darwin)
      local plist="$HOME/Library/LaunchAgents/${LABEL}.plist"
      render_launchd "$tick" "$interval" > "$plist"
      launchctl unload "$plist" 2>/dev/null || true
      launchctl load "$plist"
      echo "installed launchd agent: $plist" ;;
    *)
      local line; line="$(render_cron "$tick" "$interval")"
      ( crontab -l 2>/dev/null | grep -vF "# ${LABEL}"; printf '%s\n' "$line" ) | crontab -
      echo "installed cron line for ${LABEL}" ;;
  esac
}

case "${1:-}" in
  render-launchd) [ $# -ge 3 ] || usage; render_launchd "$2" "$3" ;;
  render-cron)    [ $# -ge 3 ] || usage; render_cron "$2" "$3" ;;
  install)        [ $# -ge 2 ] || usage; install_watcher "$2" "${3:-900}" ;;
  *)              usage ;;
esac
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/install-watcher.sh`
Expected: `PASS: install-watcher`

- [ ] **Step 5: Commit**
```bash
git add scripts/install-watcher.sh tests/install-watcher.sh
git commit -m "feat: add namespaced watcher scheduler installer (cron + launchd)"
```

---

### Task 10: staleness banner + agent/command wiring (the on-demand face)

**Files:**
- Modify: `commands/ask.md`
- Modify: `skills/ask/SKILL.md`
- Modify: `agents/vault-librarian.md`
- Test: `tests/ask-staleness.sh`

**Interfaces:**
- Consumes: `staleness_banner` (Task 1), `resolve_obsidian_config`.
- Produces: the `/obsidian:ask` flow prepends a staleness banner when the index is stale; the agent doc documents query-backend routing (frontmatter/`find-notes` for note text & structure; `recall` for cross-source; claude-mem for work history), the management skills (file/insert, cluster promotion, frontmatter fill on request, quarantine adjudication), and that QUERY never writes. The testable unit is a small bootstrap snippet `scripts/ask-staleness.sh` that prints the banner (or nothing) so the behavior is covered by a real assertion rather than only prose.

- [ ] **Step 1: Write the failing test**

Create `tests/ask-staleness.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/note-hash.sh"
. "${ROOT_DIR}/scripts/lib/keeper-state.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ask-stale-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
V="$TMP/vault"; mkdir -p "$V"; keeper_state_init "$V" >/dev/null
CFG="$TMP/obsidian.local.md"
printf -- '---\nvault_path: %s\nkeeper_interval_secs: 900\n---\n' "$V" > "$CFG"
export OBSIDIAN_LOCAL_MD="$CFG"

run() { bash "${ROOT_DIR}/scripts/ask-staleness.sh"; }

# fresh: no banner
keeper_record_scan "$V"
[ -z "$(run)" ] || fail "fresh index should not warn"
# stale: banner
printf '1000\n' > "$(keeper_cache_dir "$V")/last_scan"
[ -n "$(run)" ] || fail "stale index should warn"

echo "PASS: ask-staleness"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/ask-staleness.sh`
Expected: FAIL (`No such file or directory`).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/ask-staleness.sh`:
```bash
#!/usr/bin/env bash
# ask-staleness.sh — print a staleness banner for /obsidian:ask when the
# vaultkeeper index has not been maintained within 2x the configured interval.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/note-hash.sh"
. "${ROOT}/lib/keeper-state.sh"
. "${ROOT}/lib/resolve-config.sh"

CONFIG="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-${ROOT%/scripts}}")" || exit 0
VAULT="$(grep '^vault_path:' "$CONFIG" | head -1 | sed 's/vault_path: *//')"
[ -n "$VAULT" ] || exit 0
INTERVAL="$(grep '^keeper_interval_secs:' "$CONFIG" | head -1 | sed 's/.*: *//')"
INTERVAL="${INTERVAL:-900}"
staleness_banner "$VAULT" "$INTERVAL"
```

Then update the docs (no code execution; prose):

In `commands/ask.md`, add a line instructing the flow to run the banner first:
```markdown
Before answering, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ask-staleness.sh"`; if it prints a line, show it to the user as a `⚠` banner above the answer.
```

In `skills/ask/SKILL.md`, add the same staleness step to the QUERY path and state QUERY never writes (read-only over the live frontmatter substrate; routes to `recall` / claude-mem as typed).

In `agents/vault-librarian.md`, add a `## Query backends (typed by question)` section and a `## Management skills` section reflecting the spec:
```markdown
## Query backends (typed by question)

- **frontmatter + find-notes** → vault note text & structure (what's written, where, by type/status/tag, coverage gaps). Never read a `.base` to answer — `.base` files are write-only GUI views.
- **recall** → cross-source timeline (vault + git + GitHub + mem).
- **claude-mem graph search** → work history (what I worked on / decided), NOT note-content search.

Choose the right lens; do not query all of them.

## Management skills

- File/insert with judgment (route + template + dedup).
- Decide cluster promotion from the substrate's raw `CLUSTER` candidates.
- Fill/normalize frontmatter only when asked (never on the tick).
- Adjudicate quarantined `.sync-conflict-*` files surfaced under `.vaultkeeper-quarantine/`.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/ask-staleness.sh`
Expected: `PASS: ask-staleness`

- [ ] **Step 5: Commit**
```bash
git add scripts/ask-staleness.sh tests/ask-staleness.sh commands/ask.md skills/ask/SKILL.md agents/vault-librarian.md
git commit -m "feat: add /obsidian:ask staleness banner + keeper agent backends/skills"
```

---

### Task 11: docs + config + run-all (README, config keys, version bump)

**Files:**
- Modify: `obsidian.local.md.example`
- Modify: `README.md`
- Modify: `.claude-plugin/plugin.json`
- Create: `tests/run-all.sh`
- Test: `tests/run-all.sh` (the deliverable is itself the test harness)

**Interfaces:**
- Consumes: every `tests/*.sh`.
- Produces: documented config keys + watcher namespace, a green full suite, version bump to `1.9.0`.

- [ ] **Step 1: Write the failing test**

Create `tests/run-all.sh`:
```bash
#!/usr/bin/env bash
# run-all.sh — run every tests/*.sh (except this file); fail if any fails.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
for t in "$ROOT_DIR"/*.sh; do
  [ "$(basename "$t")" = "run-all.sh" ] && continue
  if bash "$t" >/tmp/vk-test.$$ 2>&1; then
    echo "ok   $(basename "$t")"
  else
    echo "FAIL $(basename "$t")"; cat /tmp/vk-test.$$; fails=$(( fails + 1 ))
  fi
done
rm -f /tmp/vk-test.$$
[ "$fails" -eq 0 ] || { echo "$fails suite(s) failed"; exit 1; }
echo "ALL PASS"
```

- [ ] **Step 2: Run to verify the new docs are not yet present**

Run: `grep -q 'com.nhangen.obsidian-vaultkeeper' README.md && echo FOUND || echo MISSING`
Expected: `MISSING` (README not yet updated).

- [ ] **Step 3: Make the doc/config changes**

In `obsidian.local.md.example`, add to the frontmatter (after `moc_promotion_threshold: 3`):
```yaml
frontmatter_required: tags type
keeper_host_priority: ml-1 mbp
keeper_interval_secs: 900
```
And add a section:
```markdown
## vaultkeeper (the watcher)

A deterministic substrate tick (no LLM) runs on cron (Linux) / launchd (macOS),
namespaced `com.nhangen.obsidian-vaultkeeper`, on every host that writes the
vault. It validates frontmatter against `frontmatter_required`, surfaces gaps /
unfiled notes / open `[ask]`s / promotable clusters into the machine-owned
`Librarian.md`, appends only genuinely-new items to `Pending.md`, and maintains
`_vaultkeeper.base` (a write-only GUI view — never read to answer queries).

- `frontmatter_required` — keys every note should carry (seed once via
  `scripts/seed-frontmatter-schema.sh`). The tick only *surfaces* gaps; it never
  auto-writes frontmatter.
- `keeper_host_priority` — host election order over Syncthing (highest-priority
  live host owns shared writes; others defer). `.sync-conflict-*` files on
  keeper-owned files are quarantined under `.vaultkeeper-quarantine/`, never
  deleted.
- `keeper_interval_secs` — tick cadence; the `/obsidian:ask` staleness banner
  fires past `2x` this.

State (`.state`, snapshots, `last_scan`) lives under
`${XDG_CACHE_HOME:-$HOME/.cache}/vaultkeeper/<vault-id>/`, never in the vault.
```

In `README.md`, add a `## vaultkeeper watcher` section covering: the two-layer model (deterministic substrate tick + on-demand agent), `Librarian.md` is machine-owned (edits don't persist), install via `bash scripts/install-watcher.sh install "$(pwd)/scripts/vaultkeeper-tick.sh"`, the namespace `com.nhangen.obsidian-vaultkeeper` (so a `crontab -l` / `launchctl list` audit surfaces it), and that the keeper writes only the Obsidian vault (no CEO writes).

In `.claude-plugin/plugin.json`, bump `"version": "1.8.0"` → `"version": "1.9.0"` and add `"vaultkeeper"` to `keywords`.

- [ ] **Step 4: Run the full suite**

Run: `bash tests/run-all.sh`
Expected: `ALL PASS`
Run: `grep -q 'com.nhangen.obsidian-vaultkeeper' README.md && echo FOUND`
Expected: `FOUND`

- [ ] **Step 5: Commit**
```bash
git add obsidian.local.md.example README.md .claude-plugin/plugin.json tests/run-all.sh
git commit -m "docs: document vaultkeeper watcher + config keys; add run-all; bump to 1.9.0"
```

---

## Self-Review

**1. Spec coverage** (against `docs/superpowers/specs/2026-06-19-vault-librarian-watcher-design.md`):
- Index substrate = frontmatter + write-only Bases → Tasks 2, 4, 5 (+ Global Constraint #1, enforced by `.md`-only scans and a write-only `base-views.sh` with no reader).
- Frontmatter schema configurable, seed not tick → Task 3 (+ Global Constraint).
- Two layers (deterministic substrate + agent) → Tasks 1–8 substrate; Task 10 agent layer.
- Surfacing candidates (gaps/unfiled/asks/clusters) → Task 4; digest + transition-gated Pending → Task 7.
- Watching (cron/launchd, namespaced) → Tasks 8, 9.
- Write-safety (advisory lease + deterministic election + quarantine-never-delete) → Task 6; wired owner-gated in Task 8.
- Surfacing output (`Librarian.md` atomic machine-owned + transition-gated `Pending.md` + `.base` view + no CEO writes) → Tasks 5, 7, 8, 11.
- State store non-synced under XDG cache, cold-start silent → Tasks 1, 7, 8.
- `/obsidian:ask` face + staleness banner → Task 10.
- Testing invariants (spec lines 86–97): frontmatter validation (T2), `.base` idempotent (T5), candidates (T4), transition gating (T7), cold cache (T7/T8), election incl. partial-propagation follow-up #2 (T6), quarantine (T6), atomic digest hand-edit-doesn't-survive (T7), QUERY-no-write/staleness (T10), `.state` location (T1/T8). All covered.
- Plan-time follow-ups: #1 no `.base` read (Global Constraint + T4/T5 design + T4 test asserts `.base` never appears), #2 partial-propagation election (T6 test), #3 schema-seed-not-tick (T3).

No gaps found.

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows the full test. Clear.

**3. Type consistency:** Candidate line format `KIND\t<fields>` is consistent across `vault-scan.sh` (GAP/UNFILED/ASK/CLUSTER), `keeper-lease.sh` (QUARANTINE), `surfacing.sh` (parses `kind`/`rest`), and `vaultkeeper-tick.sh` (concatenates them). Function names referenced across tasks (`keeper_has_snapshot`, `keeper_write_snapshot`, `keeper_elect`, `keeper_is_owner`, `staleness_banner`, `scan_*`, `surfacing_*`, `base_view_write`) match their definitions. `now_epoch`/`note_hash`/`file_mtime` come from the existing `note-hash.sh`. Consistent.
