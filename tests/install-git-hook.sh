#!/usr/bin/env bash
# tests/install-git-hook.sh — Comprehensive unit and integration tests for install-git-hook.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
INSTALLER="${REPO_ROOT}/scripts/install-git-hook.sh"

export GIT_AUTHOR_NAME="Nathan Hangen"
export GIT_AUTHOR_EMAIL="nhangen@gmail.com"
export GIT_COMMITTER_NAME="Nathan Hangen"
export GIT_COMMITTER_EMAIL="nhangen@gmail.com"

TEST_TMP=""
cleanup() {
  if [ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}
trap cleanup EXIT

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-hook-test.XXXXXX")"

# Isolated HOME and git configuration
export HOME="${TEST_TMP}/home"
export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
mkdir -p "$HOME"

# 1. Render test
RENDER_OUT="$("${INSTALLER}" render)"
case "$RENDER_OUT" in
  *"# obsidian-commit-capture-hook"*) ;;
  *) echo "FAIL: render output missing marker" >&2; exit 1 ;;
esac

# 2. Fresh repository installation, status, and end-to-end vault commit capture
FRESH_REPO="${TEST_TMP}/fresh-repo"
git init -b main "$FRESH_REPO" >/dev/null

MOCK_VAULT="${TEST_TMP}/mock-vault"
mkdir -p "$MOCK_VAULT"
CFG_FILE="${TEST_TMP}/vault-config.yaml"
printf -- '---\nvault_path: %s\n---\n' "$MOCK_VAULT" > "$CFG_FILE"
export OBSIDIAN_LOCAL_MD="$CFG_FILE"

STATUS_BEFORE="$("${INSTALLER}" status "$FRESH_REPO" || true)"
[ "$STATUS_BEFORE" = "not-installed" ] || { echo "FAIL: status before install expected not-installed, got $STATUS_BEFORE" >&2; exit 1; }

INSTALL_OUT="$("${INSTALLER}" install "$FRESH_REPO")"
[ "$INSTALL_OUT" = "installed" ] || { echo "FAIL: install expected installed, got $INSTALL_OUT" >&2; exit 1; }

STATUS_AFTER="$("${INSTALLER}" status "$FRESH_REPO")"
[ "$STATUS_AFTER" = "installed" ] || { echo "FAIL: status after install expected installed, got $STATUS_AFTER" >&2; exit 1; }

HOOK_CONTENT="$(cat "${FRESH_REPO}/.git/hooks/post-commit")"
case "$HOOK_CONTENT" in
  *"${REPO_ROOT}/scripts"*) echo "FAIL: hook remains pinned to the source checkout" >&2; exit 1 ;;
  *"obsidian-commit-capture"*) ;;
  *) echo "FAIL: hook does not reference the stable runtime bundle" >&2; exit 1 ;;
esac

# Perform a git commit in fresh repo
(
  cd "$FRESH_REPO"
  echo "content" > file.txt
  git add file.txt
  git commit --no-verify -m "test end-to-end commit capture" >/dev/null
)

TODAY="$(date '+%Y-%m-%d')"
EXPECTED_NOTE="${MOCK_VAULT}/Projects/Development/local/fresh-repo/${TODAY}.md"
[ -f "$EXPECTED_NOTE" ] || { echo "FAIL: expected note $EXPECTED_NOTE was not created by post-commit hook" >&2; exit 1; }

NOTE_CONTENT="$(cat "$EXPECTED_NOTE")"
case "$NOTE_CONTENT" in
  *"test end-to-end commit capture"*) ;;
  *) echo "FAIL: note content missing commit message" >&2; exit 1 ;;
esac

UNINSTALL_OUT="$("${INSTALLER}" uninstall "$FRESH_REPO")"
[ "$UNINSTALL_OUT" = "uninstalled" ] || { echo "FAIL: uninstall expected uninstalled, got $UNINSTALL_OUT" >&2; exit 1; }

STATUS_UNINSTALLED="$("${INSTALLER}" status "$FRESH_REPO" || true)"
[ "$STATUS_UNINSTALLED" = "not-installed" ] || { echo "FAIL: status after uninstall expected not-installed, got $STATUS_UNINSTALLED" >&2; exit 1; }

# 3. Legacy hook preservation, execution chaining, and restoration
LEGACY_REPO="${TEST_TMP}/legacy-repo"
git init -b main "$LEGACY_REPO" >/dev/null
mkdir -p "${LEGACY_REPO}/.git/hooks"

LEGACY_LOG="${TEST_TMP}/legacy-hook.log"
cat <<EOF > "${LEGACY_REPO}/.git/hooks/post-commit"
#!/usr/bin/env bash
echo "legacy post-commit executed" >> "${LEGACY_LOG}"
EOF
chmod +x "${LEGACY_REPO}/.git/hooks/post-commit"

STATUS_LEGACY_BEFORE="$("${INSTALLER}" status "$LEGACY_REPO" || true)"
[ "$STATUS_LEGACY_BEFORE" = "foreign-hook-detected" ] || { echo "FAIL: status before expected foreign-hook-detected, got $STATUS_LEGACY_BEFORE" >&2; exit 1; }

"${INSTALLER}" install "$LEGACY_REPO" >/dev/null

[ -f "${LEGACY_REPO}/.git/hooks/post-commit.legacy" ] || { echo "FAIL: post-commit.legacy not created" >&2; exit 1; }

STATUS_LEGACY_AFTER="$("${INSTALLER}" status "$LEGACY_REPO")"
[ "$STATUS_LEGACY_AFTER" = "installed (chained legacy hook active)" ] || { echo "FAIL: status with legacy expected installed (chained legacy hook active), got $STATUS_LEGACY_AFTER" >&2; exit 1; }

(
  cd "$LEGACY_REPO"
  git commit --no-verify --allow-empty -m "commit with legacy hook" >/dev/null
)

[ -f "$LEGACY_LOG" ] || { echo "FAIL: legacy hook did not execute" >&2; exit 1; }

# 4. Collision refusal when both post-commit and post-commit.legacy exist
COLLISION_REPO="${TEST_TMP}/collision-repo"
git init -b main "$COLLISION_REPO" >/dev/null
mkdir -p "${COLLISION_REPO}/.git/hooks"
touch "${COLLISION_REPO}/.git/hooks/post-commit"
touch "${COLLISION_REPO}/.git/hooks/post-commit.legacy"

if "${INSTALLER}" install "$COLLISION_REPO" >/dev/null 2>&1; then
  echo "FAIL: install should have failed on collision" >&2
  exit 1
fi

# 5. Git Worktree support
WORKTREE_REPO="${TEST_TMP}/worktree-repo"
git init -b main "$WORKTREE_REPO" >/dev/null
(
  cd "$WORKTREE_REPO"
  git commit --no-verify --allow-empty -m "initial commit" >/dev/null
  git worktree add ../worktree-child -b feature >/dev/null
)
WORKTREE_CHILD="${TEST_TMP}/worktree-child"

"${INSTALLER}" install "$WORKTREE_REPO" >/dev/null
WT_STATUS="$("${INSTALLER}" status "$WORKTREE_CHILD")"
[ "$WT_STATUS" = "installed" ] || { echo "FAIL: worktree status expected installed, got $WT_STATUS" >&2; exit 1; }

(
  cd "$WORKTREE_CHILD"
  echo "worktree edit" > wt.txt
  git add wt.txt
  git commit --no-verify -m "worktree test commit" >/dev/null
)

WT_EXPECTED_NOTE="${MOCK_VAULT}/Projects/Development/local/worktree-repo/${TODAY}.md"
[ -f "$WT_EXPECTED_NOTE" ] || { echo "FAIL: expected worktree note $WT_EXPECTED_NOTE was not created" >&2; exit 1; }
WT_NOTE_CONTENT="$(cat "$WT_EXPECTED_NOTE")"
case "$WT_NOTE_CONTENT" in
  *"worktree test commit"*) ;;
  *) echo "FAIL: note content missing worktree commit message" >&2; exit 1 ;;
esac

# 6. Respect a repository/worktree-specific core.hooksPath.
CUSTOM_REPO="${TEST_TMP}/custom-hooks-repo"
CUSTOM_HOOKS="${TEST_TMP}/custom-hooks"
GLOBAL_HOOKS_FOR_LOCAL="${TEST_TMP}/global-hooks-for-local"
git init -b main "$CUSTOM_REPO" >/dev/null
mkdir -p "$CUSTOM_HOOKS" "$GLOBAL_HOOKS_FOR_LOCAL"
git config --global core.hooksPath "$GLOBAL_HOOKS_FOR_LOCAL"
git -C "$CUSTOM_REPO" config core.hooksPath "$CUSTOM_HOOKS"
"${INSTALLER}" install "$CUSTOM_REPO" >/dev/null
[ -f "${CUSTOM_HOOKS}/post-commit" ] || { echo "FAIL: custom core.hooksPath was ignored" >&2; exit 1; }
[ ! -e "${GLOBAL_HOOKS_FOR_LOCAL}/post-commit" ] || { echo "FAIL: local install used the inherited global hooksPath" >&2; exit 1; }
[ "$("${INSTALLER}" status "$CUSTOM_REPO")" = "installed" ] || { echo "FAIL: custom hooks status did not report installed" >&2; exit 1; }
"${INSTALLER}" uninstall "$CUSTOM_REPO" >/dev/null
[ ! -e "${CUSTOM_HOOKS}/post-commit" ] || { echo "FAIL: custom hook was not removed" >&2; exit 1; }
git config --global --unset core.hooksPath

# 7. Global scope preserves a pre-existing hooksPath.
PREEXISTING_GLOBAL_HOOKS="${TEST_TMP}/preexisting-global-hooks"
mkdir -p "$PREEXISTING_GLOBAL_HOOKS"
git config --global core.hooksPath "$PREEXISTING_GLOBAL_HOOKS"
"${INSTALLER}" install --scope global >/dev/null
[ "$(git config --global core.hooksPath)" = "$PREEXISTING_GLOBAL_HOOKS" ] || { echo "FAIL: pre-existing global hooksPath was changed" >&2; exit 1; }
"${INSTALLER}" uninstall --scope global >/dev/null
[ "$(git config --global core.hooksPath)" = "$PREEXISTING_GLOBAL_HOOKS" ] || { echo "FAIL: pre-existing global hooksPath was unset" >&2; exit 1; }
git config --global --unset core.hooksPath

# 8. Global scope test
GLOBAL_STATUS_BEFORE="$("${INSTALLER}" status --scope global || true)"
[ "$GLOBAL_STATUS_BEFORE" = "not-installed" ] || { echo "FAIL: global status before expected not-installed, got $GLOBAL_STATUS_BEFORE" >&2; exit 1; }

"${INSTALLER}" install --scope global >/dev/null
GLOBAL_STATUS_AFTER="$("${INSTALLER}" status --scope global)"
[ "$GLOBAL_STATUS_AFTER" = "installed" ] || { echo "FAIL: global status after expected installed, got $GLOBAL_STATUS_AFTER" >&2; exit 1; }

"${INSTALLER}" uninstall --scope global >/dev/null
GLOBAL_STATUS_UNINSTALLED="$("${INSTALLER}" status --scope global || true)"
[ "$GLOBAL_STATUS_UNINSTALLED" = "not-installed" ] || { echo "FAIL: global status uninstalled expected not-installed, got $GLOBAL_STATUS_UNINSTALLED" >&2; exit 1; }

# 9. Non-blocking error handling and surfaced capture failures
BROKEN_HOOK_DIR="${TEST_TMP}/broken-hook-dir"
mkdir -p "$BROKEN_HOOK_DIR"
"${INSTALLER}" render "/nonexistent/path/commit-meta.sh" "/nonexistent/path/keeper" > "${BROKEN_HOOK_DIR}/post-commit"
chmod +x "${BROKEN_HOOK_DIR}/post-commit"

BROKEN_REPO="${TEST_TMP}/broken-repo"
git init -b main "$BROKEN_REPO" >/dev/null
mkdir -p "${BROKEN_REPO}/.git/hooks"
cp "${BROKEN_HOOK_DIR}/post-commit" "${BROKEN_REPO}/.git/hooks/post-commit"

(
  cd "$BROKEN_REPO"
  git commit --no-verify --allow-empty -m "commit with broken hook paths" >/dev/null 2>&1
) || { echo "FAIL: git commit failed on broken hook paths" >&2; exit 1; }

BROKEN_ERR="${TEST_TMP}/broken-hook.err"
(cd "$BROKEN_REPO" && ./.git/hooks/post-commit 2>"$BROKEN_ERR")
grep -q "commit-meta executable not found" "$BROKEN_ERR" || { echo "FAIL: broken capture path was not surfaced" >&2; exit 1; }

echo "ok   install-git-hook.sh"
