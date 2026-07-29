#!/usr/bin/env bash
# Exercises scripts/commit-capture.sh's commit-detection gate and its
# org/repo derivation.
#
# Two regressions, both silent:
#   1. The gate required the "[branch hash]" summary line in the tool output.
#      `git commit -q` prints nothing, so every quiet commit was skipped and its
#      capture lost — 12 days of mtf-builder history, discovered 2026-07-28.
#   2. The derivation matched SSH and github.com only, so an HTTPS GitLab remote
#      fell through to local/<repo>. The same repo was captured under three
#      different org_repo values and its notes landed in three folders.
#
# Reverting either fix must fail this suite.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/commit-capture.sh"
GIT_BIN_DIR=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() { [ -n "$GIT_BIN_DIR" ] && rm -rf "$GIT_BIN_DIR"; }
trap cleanup EXIT

# Stub git so we control HEAD's age and the remote URL without a real repo.
# $1 = commit timestamp (epoch seconds), $2 = remote URL
make_git_stub() {
  local ct="$1" remote="$2"
  GIT_BIN_DIR="${GIT_BIN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/cc-det-git-XXXXXX")}"
  cat > "${GIT_BIN_DIR}/git" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "log -1 --format=%ct") echo "${ct}" ;;
  "rev-parse --short HEAD") echo abc1234 ;;
  "log -1 --pretty=format:%s") echo "test commit" ;;
  "rev-parse --abbrev-ref HEAD") echo nh/feat/test ;;
  "diff --name-only HEAD~1..HEAD") echo foo.txt ;;
  "remote get-url origin") echo "${remote}" ;;
  "rev-parse --show-toplevel") echo "/tmp/mtf-builder" ;;
  *) echo "" ;;
esac
STUB
  chmod +x "${GIT_BIN_DIR}/git"
}

run_hook() {
  PATH="${GIT_BIN_DIR}:$PATH" bash "$SCRIPT" 2>/dev/null || true
}

NOW="$(date +%s)"

# --- 1. a QUIET commit is captured (no "[branch hash]" line anywhere) ---------
make_git_stub "$NOW" "git@github.com:nhangen/test.git"
OUT="$(printf '%s' '{"tool_input":{"command":"cd /repo && git commit -q -F -"},"tool_response":{"stdout":""}}' | run_hook)"
case "$OUT" in
  *hash=abc1234*) : ;;
  *) fail "quiet commit not captured (this is the -q regression)"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# --- 2. a non-quiet commit still works ---------------------------------------
OUT="$(printf '%s' '{"tool_input":{"command":"git commit -F -"},"tool_response":{"stdout":"[dev abc1234] test commit\n 1 file changed"}}' | run_hook)"
case "$OUT" in
  *hash=abc1234*) : ;;
  *) fail "non-quiet commit stopped being captured"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# --- 3. a stale HEAD is NOT captured -----------------------------------------
# A `git commit` that failed leaves an older HEAD; capturing it would attribute
# the previous commit to this call.
make_git_stub "$(( NOW - 4000 ))" "git@github.com:nhangen/test.git"
OUT="$(printf '%s' '{"tool_input":{"command":"git commit -q -F -"},"tool_response":{"stdout":""}}' | run_hook)"
[ -z "$OUT" ] || fail "stale HEAD was captured; the recency window is not enforced"$'\n'"got: $OUT"

# --- 4. non-commit Bash calls stay silent ------------------------------------
make_git_stub "$NOW" "git@github.com:nhangen/test.git"
OUT="$(printf '%s' '{"tool_input":{"command":"git status"},"tool_response":{"stdout":"nothing"}}' | run_hook)"
[ -z "$OUT" ] || fail "non-commit command produced output: $OUT"

OUT="$(printf '%s' '{"tool_input":{"command":"git commit --dry-run"},"tool_response":{"stdout":""}}' | run_hook)"
[ -z "$OUT" ] || fail "--dry-run was captured: $OUT"

OUT="$(printf '%s' '{"tool_input":{"command":"git commit -q"},"tool_response":{"stdout":"nothing to commit, working tree clean"}}' | run_hook)"
[ -z "$OUT" ] || fail "'nothing to commit' was captured: $OUT"

# --- 5. org/repo derivation across remote forms ------------------------------
check_org_repo() {
  local remote="$1" expect="$2" out
  make_git_stub "$NOW" "$remote"
  out="$(printf '%s' '{"tool_input":{"command":"git commit -q -F -"},"tool_response":{"stdout":""}}' | run_hook)"
  case "$out" in
    *"org_repo=${expect} "*|*"org_repo=${expect}") : ;;
    *) fail "remote ${remote} -> expected org_repo=${expect}"$'\n'"got: ${out:-<empty>}" ;;
  esac
}

check_org_repo "https://gitlab.com/altamira2/mtf-builder.git" "altamira2/mtf-builder"
check_org_repo "https://gitlab.com/altamira2/mtf-builder"     "altamira2/mtf-builder"
check_org_repo "git@github.com:nhangen/test.git"              "nhangen/test"
check_org_repo "https://github.com/nhangen/test.git"          "nhangen/test"
check_org_repo "git@gitlab.com:altamira2/mtf-builder.git"     "altamira2/mtf-builder"
check_org_repo "https://gitlab.com/group/sub/repo.git"        "group/sub/repo"
check_org_repo "/srv/git/bare-repo"                           "local/mtf-builder"

printf 'ok   commit-capture-detection.sh (quiet commits + host-agnostic org/repo)\n'
