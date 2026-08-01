#!/usr/bin/env bash
# Installs the Codex package in an isolated CODEX_HOME and exercises the manual
# metadata-to-keeper path from the cached installation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-plugin-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

python3 - "$ROOT_DIR" <<'PY' || fail "Codex package contract failed"
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
package = root / "packages/codex"
codex = json.loads((package / ".codex-plugin/plugin.json").read_text())
claude = json.loads((root / ".claude-plugin/plugin.json").read_text())
marketplace_legacy = json.loads((root / ".claude-plugin/marketplace.json").read_text())
assert codex["version"] == claude["version"] == marketplace_legacy["plugins"][0]["version"]
assert codex["skills"] == "./skills/"
assert "hooks" not in codex
assert [p.name for p in (package / "skills").iterdir() if p.is_dir()] == ["commit-capture"]
assert (package / "README.md").is_file()

skill_root = package / "skills/commit-capture"
skill = (skill_root / "SKILL.md").read_text()
assert skill.startswith("---\nname: commit-capture\ndescription:")
assert "commit-meta.sh" in skill
assert "--skip-if-hash" in skill
assert "awesomemotive/*" in skill
assert "altamira2/mtf-builder" in skill
assert "git remote get-url" not in skill
assert "source: codex" in skill

marketplace = json.loads((root / ".agents/plugins/marketplace.json").read_text())
entry = marketplace["plugins"][0]
assert entry["name"] == "obsidian"
assert entry["source"] == {"source": "local", "path": "./packages/codex"}

for relative in (
    "commit-meta.sh",
    "keeper",
    "lib/commit-capture-parse.sh",
    "lib/note-hash.sh",
    "lib/resolve-config.sh",
    "lib/vault-index.sh",
):
    packaged = skill_root / "scripts" / relative
    canonical = root / "scripts" / relative
    assert packaged.read_bytes() == canonical.read_bytes(), relative
PY

command -v codex >/dev/null 2>&1 || fail "codex CLI is required for the installation smoke test"
CODEX_HOME_DIR="$TMP/codex-home"
mkdir -p "$CODEX_HOME_DIR"
CODEX_HOME="$CODEX_HOME_DIR" codex plugin marketplace add "$ROOT_DIR" >/dev/null
CODEX_HOME="$CODEX_HOME_DIR" codex plugin add obsidian@nhangen-codex-plugins >/dev/null

VERSION="$(python3 - "$ROOT_DIR/packages/codex/.codex-plugin/plugin.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["version"])
PY
)"
INSTALLED="$CODEX_HOME_DIR/plugins/cache/nhangen-codex-plugins/obsidian/$VERSION"
SKILL_ROOT="$INSTALLED/skills/commit-capture"
[ -f "$SKILL_ROOT/SKILL.md" ] || fail "installed skill is missing"
[ ! -e "$INSTALLED/hooks/hooks.json" ] || fail "manual Codex package unexpectedly installed hooks"

REPO="$TMP/repo"
VAULT="$TMP/vault"
CFG="$TMP/obsidian.local.md"
mkdir -p "$REPO" "$VAULT"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" config user.email codex@example.com
git -C "$REPO" config user.name Codex
git -C "$REPO" remote add origin https://oauth2:SECRET_TOKEN@github.com/nhangen/codex-fixture.git
printf 'captured\n' > "$REPO/work.txt"
git -C "$REPO" add work.txt
git -C "$REPO" commit -q -m test-codex-capture
printf -- '---\nvault_path: %s\n---\n' "$VAULT" > "$CFG"

RECORD="$(OBSIDIAN_LOCAL_MD="$CFG" bash "$SKILL_ROOT/scripts/commit-meta.sh" -C "$REPO")"
case "$RECORD" in
  *SECRET_TOKEN*) fail "commit-meta exposed remote userinfo" ;;
esac
case "$RECORD" in
  *'org_repo=nhangen/codex-fixture'*'vault_path='*'msg=test-codex-capture') : ;;
  *) fail "installed commit-meta returned an invalid record: $RECORD" ;;
esac

HASH="$(printf '%s' "$RECORD" | sed -n 's/^hash=\([^ ]*\).*/\1/p')"
TODAY="$(date '+%Y-%m-%d')"
TARGET="Projects/Development/nhangen/codex-fixture/$TODAY.md"
BODY="$TMP/body.md"
INIT="$TMP/init.md"
printf '%s\n' '**Branch:** master' '**Message:** test-codex-capture' '**Files:** work.txt' '' '### Context' '' '- Goal: verify the installed manual Codex capture path.' '' '---' > "$BODY"
printf -- '%s\n' '---' "date: $TODAY" 'repo: nhangen/codex-fixture' 'tags: [codex-fixture, auto-captured]' 'source: codex' '---' '' "# codex-fixture - $TODAY" > "$INIT"

bash "$SKILL_ROOT/scripts/keeper" append \
  --vault "$VAULT" --target "$TARGET" --section "## 12:00 - $HASH" \
  --body-file "$BODY" --init-file "$INIT" --skip-if-hash "$HASH" >/dev/null
SECOND_ERR="$TMP/second.err"
bash "$SKILL_ROOT/scripts/keeper" append \
  --vault "$VAULT" --target "$TARGET" --section "## 12:00 - $HASH" \
  --body-file "$BODY" --init-file "$INIT" --skip-if-hash "$HASH" >/dev/null 2>"$SECOND_ERR"
grep -q 'append skipped' "$SECOND_ERR" || fail "installed keeper did not report idempotent skip"
[ "$(grep -c "^## 12:00 - $HASH$" "$VAULT/$TARGET")" -eq 1 ] || fail "installed keeper duplicated the commit"
grep -q '^source: codex$' "$VAULT/$TARGET" || fail "installed capture lost Codex provenance"

if env -u OBSIDIAN_LOCAL_MD XDG_CONFIG_HOME="$TMP/no-config" \
  bash "$SKILL_ROOT/scripts/commit-meta.sh" -C "$REPO" >"$TMP/missing.out" 2>"$TMP/missing.err"; then
  fail "commit-meta succeeded without a configured vault"
fi
grep -q 'vault_path unresolved' "$TMP/missing.err" || fail "missing config failure was not truthful"

printf 'PASS: installed Codex manual commit-capture package\n'
