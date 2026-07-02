# Vaultkeeper "Sole Brain" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each deterministic "where does this note go / is it a duplicate" rule a single sourced-shell implementation, and single-source the fuzzy routing prose, so the rules stop being re-described across skills/agent and drifting.

**Architecture:** Two new sourced shell libs under `scripts/lib/` (matching `note-hash.sh`/`vault-index.sh`): `dedup-scan.sh` (slug tokenizer + Jaccard + same-day scan) and `allowlist-validate.sh` (taxonomy allow-list parse + target validation). The three consumers (`save-conversation`, `create-note`, `vault-librarian`) stop re-describing the deterministic logic and call the libs; the semantic-routing prose moves to one canonical home (`## Routing Rules` in the config) that reads its folder set from the taxonomy table via `allowlist_list`.

**Tech Stack:** POSIX-ish bash sourced libs, zsh-clean (repo runs tests under both). `awk`/`tr`/`comm`. No new deps.

## Global Constraints

- Libs must be zsh-clean AND bash-clean — no bash-only traps (`trap … RETURN`), `$0`-inside-function assumptions, `flock`, or `realpath`. The keeper-cli suite runs libs under `zsh`.
- `tokenize_slug` is the ONE tokenizer: same-day dedup and MOC-promotion must both use it. No second copy.
- Routing prose must NOT hardcode folder names — valid targets are whatever `allowlist_list` emits from the `## Project Taxonomy` table.
- Do not re-add a subagent dispatch to any common write path.
- Code comments: only where the *why* is non-obvious. No narration.
- Every new `tests/*.sh` is auto-discovered by `tests/run-all.sh` — no runner edits.
- Commit messages: no "claude"/"anthropic"/"co-authored".

---

### Task 1: `dedup-scan.sh` lib

**Files:**
- Create: `scripts/lib/dedup-scan.sh`
- Test: `tests/dedup-scan.sh`

**Interfaces:**
- Produces: `tokenize_slug <slug>` (emits kept tokens, one per line); `jaccard <slug-a> <slug-b>` (echoes `0.00`–`1.00`); `dedup_same_day <folder> <date> <slug> [threshold=0.4]` (echoes `path\tscore` for the best same-day match ≥ threshold, else nothing).

- [ ] **Step 1: Write the failing test** — `tests/dedup-scan.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/dedup-scan.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dedup-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# tokenize_slug: drop purely-numeric and 1-char tokens, keep 2-char, lowercase
got="$(tokenize_slug "2026-06-29-Keeper-a-PR-ai" | tr '\n' ' ')"
[ "$got" = "keeper pr ai " ] || fail "tokenize_slug got: [$got]"

# jaccard: identical slugs = 1.00, disjoint = 0.00
[ "$(jaccard keeper-cli keeper-cli)" = "1.00" ] || fail "jaccard identical"
[ "$(jaccard alpha-beta gamma-delta)" = "0.00" ] || fail "jaccard disjoint"
# half overlap: {keeper,cli} vs {keeper,gui} -> inter 1 / union 3 = 0.33
[ "$(jaccard keeper-cli keeper-gui)" = "0.33" ] || fail "jaccard partial: $(jaccard keeper-cli keeper-gui)"

# dedup_same_day: same-day match above threshold is found; other-day ignored
mkdir -p "$TMP/f"
: > "$TMP/f/2026-06-29-keeper-cli-design.md"
: > "$TMP/f/2026-06-28-keeper-cli-notes.md"   # different day — must be ignored
hit="$(dedup_same_day "$TMP/f" 2026-06-29 keeper-cli-plan 0.4)"
echo "$hit" | grep -q '2026-06-29-keeper-cli-design.md' || fail "same-day match not found: [$hit]"
echo "$hit" | grep -q '2026-06-28' && fail "other-day file wrongly matched"
# below threshold -> no output
[ -z "$(dedup_same_day "$TMP/f" 2026-06-29 totally-unrelated-topic 0.4)" ] || fail "below-threshold should be empty"

# zsh cleanliness
if command -v zsh >/dev/null 2>&1; then
  zsh -c ". '$ROOT_DIR/scripts/lib/dedup-scan.sh'; tokenize_slug a-2026-bb" >/dev/null 2>"$TMP/zerr" || { cat "$TMP/zerr" >&2; fail "dedup-scan broke under zsh"; }
  grep -qi 'undefined signal\|bad pattern\|parse error' "$TMP/zerr" && { cat "$TMP/zerr" >&2; fail "zsh warning in dedup-scan"; }
fi
echo "PASS: dedup-scan"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/dedup-scan.sh`
Expected: FAIL (`dedup-scan.sh` does not exist → source error).

- [ ] **Step 3: Implement `scripts/lib/dedup-scan.sh`**

```bash
#!/usr/bin/env bash
# dedup-scan.sh — slug tokenization + same-day duplicate detection for the vault keeper.
# Sourced by save-conversation, create-note, vault-librarian (dedup) and MOC-promotion (tokenizer).

tokenize_slug() {
  local slug="${1%.md}" tok
  printf '%s\n' "$slug" | tr 'A-Z' 'a-z' | tr '-' '\n' | while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in
      *[!0-9]*) : ;;
      *) continue ;;
    esac
    [ "${#tok}" -eq 1 ] && continue
    printf '%s\n' "$tok"
  done
}

jaccard() {
  local ta tb inter uni
  ta="$(tokenize_slug "$1" | sort -u)"
  tb="$(tokenize_slug "$2" | sort -u)"
  inter="$(comm -12 <(printf '%s\n' "$ta" | grep -v '^$' | sort -u) <(printf '%s\n' "$tb" | grep -v '^$' | sort -u) | grep -c .)"
  uni="$(printf '%s\n%s\n' "$ta" "$tb" | grep -v '^$' | sort -u | grep -c .)"
  [ "$uni" -eq 0 ] && { printf '0.00\n'; return; }
  awk -v i="$inter" -v u="$uni" 'BEGIN{printf "%.2f\n", i/u}'
}

dedup_same_day() {
  local folder="$1" date="$2" slug="$3" threshold="${4:-0.4}"
  local f base score best_path="" best_score="0.00"
  for f in "$folder/$date"-*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .md)"; base="${base#"$date"-}"
    score="$(jaccard "$slug" "$base")"
    if awk -v s="$score" -v t="$threshold" -v b="$best_score" 'BEGIN{exit !(s>=t && s>b)}'; then
      best_score="$score"; best_path="$f"
    fi
  done
  [ -n "$best_path" ] && printf '%s\t%s\n' "$best_path" "$best_score"
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `bash tests/dedup-scan.sh`
Expected: `PASS: dedup-scan`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/dedup-scan.sh tests/dedup-scan.sh
git commit -m "feat: dedup-scan lib (single tokenizer + Jaccard + same-day scan) (#26)"
```

---

### Task 2: `allowlist-validate.sh` lib

**Files:**
- Create: `scripts/lib/allowlist-validate.sh`
- Test: `tests/allowlist-validate.sh`

**Interfaces:**
- Consumes: `scripts/lib/resolve-config.sh` (for the default config path).
- Produces: `allowlist_list [config]` (emits each taxonomy `Vault path`, trailing slash stripped, one per line); `allowlist_validate <target> [config]` (exit 0 if target's top-level prefix is allow-listed; else print closest-match refusal to stderr, exit 1).

- [ ] **Step 1: Write the failing test** — `tests/allowlist-validate.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/allowlist-validate.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/allow-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

CFG="$TMP/cfg.md"
cat > "$CFG" <<'EOF'
## Project Taxonomy

| Domain | Vault path | Precedence | Notes |
|--------|-----------|------------|-------|
| Development | Projects/Development/ | 10 | code |
| Daily | Daily/ | 50 | dated |
| Inbox | Inbox/ | 99 | fallback |

## Routing Rules
EOF

# allowlist_list emits exactly the three rows, slash-stripped, header/separator excluded
got="$(allowlist_list "$CFG" | tr '\n' ',')"
[ "$got" = "Projects/Development,Daily,Inbox," ] || fail "allowlist_list got: [$got]"

# valid: exact root, dated subfolder, per-repo namespacing, case-insensitive
allowlist_validate "Daily/2026-06-29.md" "$CFG" || fail "dated subfolder should pass"
allowlist_validate "Projects/Development/nhangen/foo/x.md" "$CFG" || fail "namespaced path should pass"
allowlist_validate "projects/development/x.md" "$CFG" || fail "case-insensitive should pass"

# invalid: unknown top-level refused, non-zero, closest match surfaced
if allowlist_validate "Projcts/Development/x.md" "$CFG" 2>"$TMP/err"; then fail "typo top-level should be refused"; fi
grep -q 'Projects/Development' "$TMP/err" || fail "closest match not surfaced: $(cat "$TMP/err")"

# a folder that only shares a prefix substring but not a path segment is refused
if allowlist_validate "Dailyish/x.md" "$CFG" 2>/dev/null; then fail "Dailyish must not match Daily"; fi

if command -v zsh >/dev/null 2>&1; then
  zsh -c ". '$ROOT_DIR/scripts/lib/allowlist-validate.sh'; allowlist_list '$CFG'" >/dev/null 2>"$TMP/zerr" || { cat "$TMP/zerr" >&2; fail "allowlist-validate broke under zsh"; }
fi
echo "PASS: allowlist-validate"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/allowlist-validate.sh`
Expected: FAIL (source error — lib missing).

- [ ] **Step 3: Implement `scripts/lib/allowlist-validate.sh`**

```bash
#!/usr/bin/env bash
# allowlist-validate.sh — Project Taxonomy allow-list parsing + target validation.
# The taxonomy table in the config is the single source of valid top-level folders.

_allowlist_config() {
  local cfg="${1:-}"
  if [ -z "$cfg" ]; then
    cfg="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-config.sh" 2>/dev/null || true)"
  fi
  [ -n "$cfg" ] && [ -f "$cfg" ] || { printf 'allowlist: no config resolved\n' >&2; return 1; }
  printf '%s\n' "$cfg"
}

allowlist_list() {
  local cfg; cfg="$(_allowlist_config "${1:-}")" || return 1
  awk -F'|' '
    /^## Project Taxonomy/ { inseg=1; next }
    inseg && /^## / { inseg=0 }
    inseg && /^\|/ {
      v=$3; gsub(/^[ \t]+|[ \t]+$/, "", v);
      if (v=="" || v=="Vault path" || v ~ /^-+$/) next;
      sub(/\/$/, "", v);
      print v;
    }' "$cfg"
}

allowlist_validate() {
  local target="$1" cfg="${2:-}" entry ntarget nentry best="" bestd=9999 d top
  ntarget="$(printf '%s' "$target" | tr 'A-Z' 'a-z')"; ntarget="${ntarget%/}"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    nentry="$(printf '%s' "$entry" | tr 'A-Z' 'a-z')"; nentry="${nentry%/}"
    case "$ntarget/" in
      "$nentry"/*) return 0 ;;
    esac
  done < <(allowlist_list "$cfg")

  top="${target%%/*}"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    d="$(_lev "$(printf '%s' "$top" | tr 'A-Z' 'a-z')" "$(printf '%s' "${entry%%/*}" | tr 'A-Z' 'a-z')")"
    if [ "$d" -lt "$bestd" ]; then bestd="$d"; best="$entry"; fi
  done < <(allowlist_list "$cfg")

  printf 'Refusing to write to %s — top-level folder is not in the allow-list. Closest match: %s. Add it to ## Project Taxonomy or correct the target.\n' "$target" "$best" >&2
  return 1
}

_lev() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    la=length(a); lb=length(b);
    for(i=0;i<=la;i++) d[i,0]=i;
    for(j=0;j<=lb;j++) d[0,j]=j;
    for(i=1;i<=la;i++) for(j=1;j<=lb;j++){
      c=(substr(a,i,1)==substr(b,j,1))?0:1;
      m=d[i-1,j]+1; n=d[i,j-1]+1; o=d[i-1,j-1]+c;
      m=(m<n)?m:n; m=(m<o)?m:o; d[i,j]=m;
    }
    print d[la,lb];
  }'
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `bash tests/allowlist-validate.sh`
Expected: `PASS: allowlist-validate`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/allowlist-validate.sh tests/allowlist-validate.sh
git commit -m "feat: allowlist-validate lib (taxonomy parse + target validation) (#26)"
```

---

### Task 3: Retrofit `save-conversation` to the libs

**Files:**
- Modify: `skills/save-conversation/SKILL.md` (Allow-list Validation section; Same-Day Dedup section; MOC-Promotion "Tokenization for stem detection"; version frontmatter)
- Test: `tests/sole-brain-save-conversation.sh`

**Interfaces:**
- Consumes: `allowlist_validate`, `dedup_same_day`, `tokenize_slug` (Tasks 1–2).

- [ ] **Step 1: Write the failing test** — `tests/sole-brain-save-conversation.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$ROOT_DIR/skills/save-conversation/SKILL.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
need() { grep -q -- "$1" "$F" || fail "missing: $1"; }
absent() { grep -q -- "$1" "$F" && fail "should be gone (inline dup): $1"; }

need 'allowlist-validate.sh'
need 'allowlist_validate'
need 'dedup-scan.sh'
need 'dedup_same_day'
need 'tokenize_slug'
# the inline Jaccard prose must be gone (now delegated to the lib)
absent 'compute .A ∩ B'
echo "PASS: sole-brain-save-conversation"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/sole-brain-save-conversation.sh`
Expected: FAIL (`missing: allowlist-validate.sh`).

- [ ] **Step 3: Edit `skills/save-conversation/SKILL.md`**

Replace the body of the **Allow-list Validation (strict_domains)** section's numbered steps with a lib call, keeping the strict-mode gate:

```markdown
When strict mode is on, validate the resolved target:

Source the shared validator and call it — do not re-implement the parse/normalize/prefix logic:

    . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/allowlist-validate.sh"
    if ! allowlist_validate "<target>"; then
      # allowlist_validate printed the refusal + closest match to stderr; surface it and stop.
      exit 0
    fi

`allowlist_validate` reads the `## Project Taxonomy` table as the canonical allow-list, normalizes case, matches the target's top-level prefix (dated subfolders and per-repo namespacing under a root are valid), and on failure prints the closest match. Do not create unrecognized top-level folders.
```

Replace the **Same-Day Dedup Check** "Steps" 1–2 (glob + hand-rolled Jaccard) with:

```markdown
1. Source the shared scanner and call it:

       . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/dedup-scan.sh"
       dedup_same_day "<vault>/<target-folder>" "$(date +%Y-%m-%d)" "<proposed-slug>" "${dedup_jaccard_threshold:-0.4}"

   `dedup_same_day` globs today's notes in the folder, scores each slug's token Jaccard against the proposed slug (via the single `tokenize_slug`), and echoes `path<TAB>score` for the best match at or above the threshold, or nothing.
2. If it echoed a match, prompt the user (append vs new), as below.
```

In **MOC-Promotion → Tokenization for stem detection**, replace the "split slug on `-`, lowercase, drop tokens…" description with:

```markdown
Tokenize every candidate slug with the shared `tokenize_slug` (source `dedup-scan.sh`) — the same tokenizer the dedup check uses, so the two never diverge:

    . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/dedup-scan.sh"
    tokenize_slug "<slug>"
```

Bump the `version:` frontmatter (e.g. `1.1.0` → `1.2.0`).

- [ ] **Step 4: Run it, verify it passes**

Run: `bash tests/sole-brain-save-conversation.sh`
Expected: `PASS: sole-brain-save-conversation`

- [ ] **Step 5: Commit**

```bash
git add skills/save-conversation/SKILL.md tests/sole-brain-save-conversation.sh
git commit -m "refactor: save-conversation routes allow-list/dedup/tokenizer to shared libs (#26)"
```

---

### Task 4: Retrofit `create-note` allow-list to the lib

**Files:**
- Modify: `skills/create-note/SKILL.md:52-58` (Validate allow-list step; version frontmatter)
- Test: `tests/sole-brain-create-note.sh`

**Interfaces:**
- Consumes: `allowlist_validate` (Task 2).

- [ ] **Step 1: Write the failing test** — `tests/sole-brain-create-note.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$ROOT_DIR/skills/create-note/SKILL.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
grep -q -- 'allowlist-validate.sh' "$F" || fail "missing lib source"
grep -q -- 'allowlist_validate' "$F" || fail "missing lib call"
grep -q -- 'Levenshtein' "$F" && fail "inline allow-list algorithm should be gone"
echo "PASS: sole-brain-create-note"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/sole-brain-create-note.sh`
Expected: FAIL (`missing lib source`).

- [ ] **Step 3: Edit `skills/create-note/SKILL.md`**

Replace step 6 (**Validate allow-list**) sub-bullets with:

```markdown
6. **Validate allow-list** — `strict_domains` defaults to `true` when absent; only an explicit `false` skips validation. When on, source the shared validator and call it — do not re-implement the parse/normalize/prefix/closest-match logic:

       . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/allowlist-validate.sh"
       if ! allowlist_validate "<resolved-target>"; then
         # refusal + closest match already printed to stderr; surface it and stop.
         exit 0
       fi

   Do not create unrecognized top-level folders.
```

Bump the `version:` frontmatter (`1.1.0` → `1.2.0`).

- [ ] **Step 4: Run it, verify it passes**

Run: `bash tests/sole-brain-create-note.sh`
Expected: `PASS: sole-brain-create-note`

- [ ] **Step 5: Commit**

```bash
git add skills/create-note/SKILL.md tests/sole-brain-create-note.sh
git commit -m "refactor: create-note routes allow-list to shared lib (#26)"
```

---

### Task 5: Retrofit `vault-librarian` to the libs (after sourcing check)

**Files:**
- Modify: `agents/vault-librarian.md` (Bootstrap block; INSERT dedup step; allow-list references)
- Test: `tests/vault-librarian-agent.sh` (extend existing suite)

**Interfaces:**
- Consumes: `allowlist_validate`, `dedup_same_day` (Tasks 1–2).

**Pre-check (do this first, record the result in the report):** the agent's Bootstrap already sources libs via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/…` (`note-hash.sh`, `vault-index.sh`). Confirm those two `.` lines exist in the current `agents/vault-librarian.md` bootstrap. If they do, adding two more `.` lines is the same contract — proceed. If they do NOT (unexpected), STOP and report; do not guess a different sourcing mechanism.

- [ ] **Step 1: Add failing assertions to `tests/vault-librarian-agent.sh`**

Append before the final `echo`:

```bash
need '/scripts/lib/allowlist-validate.sh'
need 'allowlist_validate'
need '/scripts/lib/dedup-scan.sh'
need 'dedup_same_day'
```

(The suite already defines `need`.)

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/vault-librarian-agent.sh`
Expected: FAIL (`allowlist-validate.sh` not referenced yet).

- [ ] **Step 3: Edit `agents/vault-librarian.md`**

In the **Bootstrap** fenced block, add after the existing `.` lines:

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/allowlist-validate.sh"
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/dedup-scan.sh"
```

In **INSERT → step 2 (Dedup)**, replace the "run the find-notes skill / scan the target INDEX for near-duplicates (Jaccard ~0.4)" instruction with:

```markdown
2. **Dedup:** call the shared scanner — `dedup_same_day "<vault>/<folder>" "$(date +%Y-%m-%d)" "<slug>"`. If it echoes a `path<TAB>score`, surface that note and ask whether to append rather than file a duplicate — never silently merge.
```

Where the routing/INSERT text validates the target against the allow-list, have it call `allowlist_validate "<target>"` (source added in bootstrap) instead of describing the check.

- [ ] **Step 4: Run it, verify it passes**

Run: `bash tests/vault-librarian-agent.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add agents/vault-librarian.md tests/vault-librarian-agent.sh
git commit -m "refactor: vault-librarian sources shared allow-list/dedup libs (#26)"
```

---

### Task 6: Single-source the routing prose

**Files:**
- Modify: `obsidian.local.md.example` (the in-repo config template — verified to carry both `## Routing Rules` and `## Project Taxonomy`). Add the canonical routing block to its `## Routing Rules` section.
- Modify: `skills/save-conversation/SKILL.md`, `skills/create-note/SKILL.md`, `agents/vault-librarian.md` — replace inline routing prose with a reference to the canonical block.
- Test: `tests/sole-brain-routing-single-source.sh`

Note: the live config the skills read at runtime is the user's resolved `obsidian.local.md`; the canonical block ships in `obsidian.local.md.example` (what `setup` generates) and the skills reference "the resolved config's `## Routing Rules`."

**Interfaces:**
- Consumes: `allowlist_list` (Task 2) — the canonical prose points at it for the folder set.

- [ ] **Step 1: Write the failing test** — `tests/sole-brain-routing-single-source.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMPL="$ROOT_DIR/obsidian.local.md.example"
[ -f "$TMPL" ] || fail "config template obsidian.local.md.example missing"
grep -q '## Routing Rules' "$TMPL" || fail "template has no ## Routing Rules"
# canonical routing block references the taxonomy table via allowlist_list, not hardcoded folders
grep -q 'allowlist_list' "$TMPL" || fail "canonical routing prose must point at allowlist_list"
# consumers reference the canonical source rather than re-describing candidate collection
for f in skills/save-conversation/SKILL.md skills/create-note/SKILL.md agents/vault-librarian.md; do
  grep -qi 'Routing Rules' "$ROOT_DIR/$f" || fail "$f does not reference the canonical Routing Rules"
done
echo "PASS: sole-brain-routing-single-source"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/sole-brain-routing-single-source.sh`
Expected: FAIL (`allowlist_list` not referenced in the template).

- [ ] **Step 3: Edit the canonical config template + consumers**

In the config template's `## Routing Rules` section, add:

```markdown
Valid target folders are exactly what `allowlist_list` emits from the `## Project Taxonomy` table above — never hardcode folder names here or in any skill. To route: match the note's dominant topic(s) to the taxonomy Domain keywords, collect every candidate, and when 2+ match, prefer the lowest `Precedence`. This block is the single source of routing rules; skills reference it rather than restating it.
```

In each consumer, replace the inline "match dominant topics against keywords / collect candidates" prose with:

```markdown
Route per the canonical **## Routing Rules** in the resolved config (valid folders = `allowlist_list`; lowest `Precedence` wins on multi-match). Do not restate the rules here.
```

Keep the cross-domain tiebreaker and MOC prompt bodies in `save-conversation` (single-site, not duplicated).

- [ ] **Step 4: Run it, verify it passes**

Run: `bash tests/sole-brain-routing-single-source.sh`
Expected: `PASS: sole-brain-routing-single-source`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: single-source routing prose in ## Routing Rules, referencing allowlist_list (#26)"
```

---

### Task 7: Full suite + version bump

**Files:**
- Modify: `.claude-plugin/plugin.json` (version); the marketplace source entry version if this repo carries it.

- [ ] **Step 1: Run the full suite**

Run: `bash tests/run-all.sh`
Expected: `ALL PASS` (new suites `dedup-scan`, `allowlist-validate`, `sole-brain-*` included; existing suites still green).

- [ ] **Step 2: Bump plugin version**

Edit `.claude-plugin/plugin.json` `"version"` `1.15.0` → `1.16.0`.

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "chore: v1.16.0 — sole-brain shared routing/dedup libs (#26)"
```

---

## Self-Review

**Spec coverage:** allowlist-validate lib (Task 2) ✓; dedup-scan lib + single tokenizer (Task 1) ✓; save-conversation retrofit (Task 3) ✓; create-note retrofit (Task 4) ✓; vault-librarian retrofit + sourcing check (Task 5) ✓; canonical routing prose pointing at `allowlist_list`, HIGH seam #1 (Task 6) ✓; tokenizer parity / HIGH seam #2 — the shared `tokenize_slug` used by both dedup (Task 1) and MOC (Task 3 wires MOC to it) ✓; testing incl. zsh ✓.

**Placeholder scan:** every code/test step carries complete code; `<target>`/`<slug>`/`<vault>` are documented call-site substitutions the executing agent fills from context, not plan gaps.

**Type consistency:** `tokenize_slug`, `jaccard`, `dedup_same_day`, `allowlist_list`, `allowlist_validate` used with identical names/args across Tasks 1–6.
