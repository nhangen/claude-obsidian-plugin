# Keeper-Save Entry Point — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add an agent-facing `keeper-save` skill so any agent can hand the vaultkeeper a structured payload `{title, body, folder_hint?, links?, type?}` and get a keeper-committed note back — while anything that doesn't call it bypasses unchanged. Plus a small dependency-free payload validator with a test.

**Architecture:** A thin skill (mirrors the existing `ask` skill) that validates the payload via a pure-bash helper, then dispatches the existing `vault-librarian` INSERT with the structured fields and relays the committed path. No new routing logic — it reuses the librarian. Migrates zero existing writers.

**Tech Stack:** Bash (macOS BSD + Linux GNU portable), existing `scripts/lib/*`, SKILL.md. No new runtime deps (no jq).

## Global Constraints

- Repo `~/ML-AI/claude/obsidian-plugin`; branch off `main`; **do not push** (user approval required).
- Commit messages: no "claude"/"co-authored"/"anthropic".
- bash 3.2 floor (macOS keeper host): NO `declare -A`.
- Portability: no chained `if command -v` tool fallback; follow `note-hash.sh` sequential-empty-check style.
- The skill must NOT re-implement routing/templates — it dispatches `vault-librarian` INSERT, which owns those.
- Skill `name:` frontmatter is bare (`keeper-save`), per plugin convention.
- Payload format is a simple line block (dependency-free), NOT JSON: `title:`/`folder_hint:`/`type:`/`links:` header lines, then a `---` marker, then the body. (Avoids a JSON parser dep.)

---

### Task 1: Branch + baseline

- [ ] **Step 1: Parity + branch**
```bash
cd ~/ML-AI/claude/obsidian-plugin && git fetch origin main -q \
  && [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ] && echo "PARITY OK" \
  && git switch -c nh/feat/keeper-save-entrypoint main && git branch --show-current
```
Expected: `PARITY OK`, then on `nh/feat/keeper-save-entrypoint`. If not parity, fast-forward main first.

---

### Task 2: keeper-save-payload.sh — parse + validate the agent payload

**Files:**
- Create: `scripts/lib/keeper-save-payload.sh`
- Test: `tests/keeper-save-payload.sh`

**Interfaces (produces):**
- `kspayload_field <payload-file> <key>` → value of a header line `^<key>:` (trimmed), empty if absent. Keys: `title`, `folder_hint`, `type`, `links`.
- `kspayload_body <payload-file>` → everything after the first line equal to `---`.
- `kspayload_validate <payload-file>` → exit 0 if `title` non-empty AND body non-empty; else print `keeper-save: missing required field: <title|body>` to stderr and exit 1.
- `kspayload_links <payload-file>` → the `links:` value split on commas, one `[[trimmed]]` per line (empty if none).

- [ ] **Step 1: Write the failing test**

Create `tests/keeper-save-payload.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/keeper-save-payload.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ksp-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ok.md" <<'EOF'
title: Long-arc finding on X
folder_hint: CEO/agents/hari-seldon
type: finding
links: Note A, Note B
---
The body of the finding.
Second line.
EOF

[ "$(kspayload_field "$TMP/ok.md" title)" = "Long-arc finding on X" ] || fail "title parse"
[ "$(kspayload_field "$TMP/ok.md" folder_hint)" = "CEO/agents/hari-seldon" ] || fail "folder_hint parse"
[ "$(kspayload_field "$TMP/ok.md" type)" = "finding" ] || fail "type parse"
[ "$(kspayload_body "$TMP/ok.md" | head -1)" = "The body of the finding." ] || fail "body parse"
[ "$(kspayload_links "$TMP/ok.md")" = "$(printf -- '[[Note A]]\n[[Note B]]')" ] || fail "links normalize"
kspayload_validate "$TMP/ok.md" || fail "valid payload should pass"

# missing title
cat > "$TMP/notitle.md" <<'EOF'
type: note
---
body here
EOF
kspayload_validate "$TMP/notitle.md" 2>/dev/null && fail "missing title must fail"

# missing body (no --- / empty after marker)
cat > "$TMP/nobody.md" <<'EOF'
title: Has title only
---
EOF
kspayload_validate "$TMP/nobody.md" 2>/dev/null && fail "missing body must fail"

echo "PASS: keeper-save-payload"
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bash tests/keeper-save-payload.sh`
Expected: FAIL (`kspayload_field: command not found`).

- [ ] **Step 3: Minimal implementation**

Create `scripts/lib/keeper-save-payload.sh`:
```bash
#!/usr/bin/env bash
# keeper-save-payload.sh — parse + validate the agent-facing keeper-save payload.
# Format: header lines `key: value` (title/folder_hint/type/links), then a line
# that is exactly `---`, then the body. Dependency-free (no JSON parser).

kspayload_field() {
  awk -v k="$2" '
    $0=="---" { exit }
    {
      idx=index($0,":")
      if (idx>0) {
        key=substr($0,1,idx-1)
        if (key==k) { v=substr($0,idx+1); sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v); print v; exit }
      }
    }
  ' "$1"
}

kspayload_body() {
  awk 'seen{print} $0=="---"{seen=1}' "$1"
}

kspayload_validate() {
  local title body
  title="$(kspayload_field "$1" title)"
  if [ -z "$title" ]; then
    printf 'keeper-save: missing required field: title\n' >&2; return 1
  fi
  body="$(kspayload_body "$1" | sed '/^[[:space:]]*$/d')"
  if [ -z "$body" ]; then
    printf 'keeper-save: missing required field: body\n' >&2; return 1
  fi
}

kspayload_links() {
  local raw="$(kspayload_field "$1" links)"
  [ -z "$raw" ] && return 0
  printf '%s' "$raw" | tr ',' '\n' | while IFS= read -r l; do
    l="$(printf '%s' "$l" | sed 's/^[ \t]*//; s/[ \t]*$//')"
    [ -n "$l" ] && printf '[[%s]]\n' "$l"
  done
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bash tests/keeper-save-payload.sh`
Expected: `PASS: keeper-save-payload`

- [ ] **Step 5: Commit**
```bash
git add scripts/lib/keeper-save-payload.sh tests/keeper-save-payload.sh
git commit -m "feat: add keeper-save payload parser + validator"
```

---

### Task 3: keeper-save skill + docs + version bump

**Files:**
- Create: `skills/keeper-save/SKILL.md`
- Modify: `.claude-plugin/plugin.json` (version bump), `README.md` (document the entry point)

**Interfaces:** consumes Task 2's validator; dispatches the existing `vault-librarian` INSERT.

- [ ] **Step 1: Write the skill**

Create `skills/keeper-save/SKILL.md` (frontmatter `name: keeper-save`, bare). It must:
- State it is the **agent-facing** way to file a note through the keeper (humans use `/obsidian:ask`); triggers when another agent/skill needs to persist a structured note.
- Document the payload contract verbatim: `title:` (required), `folder_hint:` (optional), `type:` (optional), `links:` (optional, comma-separated), `---`, then body (required).
- Steps: (1) write the payload to a temp file; (2) `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/keeper-save-payload.sh"`-source and run `kspayload_validate` — on failure, return the error and stop, no write; (3) run `ask-staleness.sh` and surface any banner; (4) dispatch the `vault-librarian` subagent with operation hint `INSERT`, passing title/body/folder_hint/type and the normalized `kspayload_links` output as the note's links; (5) relay the committed path back to the caller; if the librarian reports low-confidence routing or a near-duplicate, surface that question — do not auto-resolve.
- Explicitly state: this skill does NOT implement routing or templates; the `vault-librarian` INSERT owns those, so a keeper-saved note is identical to a librarian-filed one.
- Match the structure/voice of `skills/ask/SKILL.md`.

- [ ] **Step 2: Bump plugin version**

In `.claude-plugin/plugin.json` bump `version` (1.9.4 → 1.10.0). If a marketplace entry references the version, update it to match.

- [ ] **Step 3: Document in README**

Add a short "keeper-save (agent-facing write)" subsection: what the payload is, that calling it = opt-in and not calling = bypass, and that no existing writer is migrated by this change.

- [ ] **Step 4: Run the full test suite**

Run: `bash tests/run-all.sh` (or `for t in tests/*.sh; do bash "$t"; done`)
Expected: all PASS, including `keeper-save-payload`.

- [ ] **Step 5: Commit**
```bash
git add skills/keeper-save/SKILL.md .claude-plugin/plugin.json README.md
git status
git commit -m "feat: add agent-facing keeper-save skill (opt-in keeper write entry point)"
```

---

## Self-Review
- Spec "agent-facing structured entry point" → Task 3 skill. ✓
- "reuses librarian INSERT, no new routing" → Task 3 Step 1 explicit. ✓
- "testable payload validation, dependency-free" → Task 2 (pure awk/sed, no jq). ✓
- "migrates zero writers / bypass default" → no writer touched; README states it. ✓
- bash 3.2 / portability constraints → no assoc arrays, no `command -v` chains. ✓
- Placeholder scan: validator + test are complete code; SKILL.md is described with an explicit pattern to match (`ask`). ✓
