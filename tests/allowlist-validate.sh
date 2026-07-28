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

  # The arm above passes $CFG explicitly, so it never exercises self-resolution —
  # which is how the real failure hid. The lib locates resolve-config.sh via
  # BASH_SOURCE; zsh leaves that unset, so dirname "" -> "." and the lookup
  # silently became cwd-dependent. Under zsh from any other cwd, config
  # resolution failed and strict validation refused every target.
  OBSIDIAN_LOCAL_MD="$CFG" zsh -c "cd / && . '$ROOT_DIR/scripts/lib/allowlist-validate.sh'; allowlist_validate 'Daily/2026-06-29.md'" 2>"$TMP/zerr2" \
    || { cat "$TMP/zerr2" >&2; fail "zsh + foreign cwd: lib could not locate its own resolve-config.sh"; }
  # Same shape under bash, for symmetry — a cwd-independent lib must not care.
  OBSIDIAN_LOCAL_MD="$CFG" bash -c "cd / && . '$ROOT_DIR/scripts/lib/allowlist-validate.sh'; allowlist_validate 'Daily/2026-06-29.md'" 2>"$TMP/berr" \
    || { cat "$TMP/berr" >&2; fail "bash + foreign cwd: lib could not locate its own resolve-config.sh"; }
fi

# No config anywhere: the refusal must name the actual problem. Reporting a
# blank "Closest match:" makes a missing config look like a bad target.
EMPTY="$TMP/empty-xdg"; mkdir -p "$EMPTY"
if env -u OBSIDIAN_LOCAL_MD -u CLAUDE_PLUGIN_ROOT XDG_CONFIG_HOME="$EMPTY" \
     bash -c ". '$ROOT_DIR/scripts/lib/allowlist-validate.sh'; allowlist_validate 'Daily/x.md'" 2>"$TMP/noerr"; then
  fail "validation must fail closed when no config resolves"
fi
grep -q 'obsidian:setup' "$TMP/noerr" \
  || fail "no-config refusal should point at /obsidian:setup, got: $(cat "$TMP/noerr")"
# The symptom was the missing config being reported as an un-allow-listed target.
# Assert the absence of that claim, not the blank match it left behind: the old
# `Closest match:[[:space:]]*$` anchor could never fire, because the message
# continues past the match ("Closest match: %s. Add it to ...").
grep -q 'not in the allow-list' "$TMP/noerr" \
  && fail "no-config refusal blamed the target instead of the config: $(cat "$TMP/noerr")"

# A config that resolves but yields no allow-list rows is its own failure, and it
# reaches a different branch than the no-config case above (there, allowlist_list
# fails and short-circuits before the list is ever inspected). Both routes in:
NOTAX="$TMP/no-taxonomy.md"
cat > "$NOTAX" <<'EOF'
---
vault_path: /tmp/nowhere
---

## Routing Rules

Nothing here declares a taxonomy.
EOF
EMPTYTAX="$TMP/empty-taxonomy.md"
cat > "$EMPTYTAX" <<'EOF'
## Project Taxonomy

| Domain | Vault path | Precedence | Notes |
|--------|-----------|------------|-------|

## Routing Rules
EOF
for _cfg in "$NOTAX" "$EMPTYTAX"; do
  if allowlist_validate "Daily/x.md" "$_cfg" 2>"$TMP/taxerr"; then
    fail "validation must fail closed when the taxonomy has no rows ($_cfg)"
  fi
  grep -q 'no readable ## Project Taxonomy allow-list' "$TMP/taxerr" \
    || fail "empty-taxonomy refusal should name the taxonomy ($_cfg), got: $(cat "$TMP/taxerr")"
  grep -q 'Closest match' "$TMP/taxerr" \
    && fail "empty-taxonomy refusal must not offer a closest match ($_cfg): $(cat "$TMP/taxerr")"
done
echo "PASS: allowlist-validate"
