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

cleanup() { [ -n "$GIT_BIN_DIR" ] && rm -rf "$GIT_BIN_DIR"; [ -n "${STATE_HOME:-}" ] && rm -rf "$STATE_HOME"; }
trap cleanup EXIT

# Stub git so we control HEAD's age and the remote URL without a real repo.
# $1 = HEAD age in seconds (negative = future-dated), $2 = remote URL.
# %ct is computed when the stub RUNS, not when it is written, so a boundary
# assertion cannot drift with elapsed test time.
make_git_stub() {
  local age="$1" remote="$2"
  GIT_BIN_DIR="${GIT_BIN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/cc-det-git-XXXXXX")}"
  cat > "${GIT_BIN_DIR}/git" <<STUB
#!/usr/bin/env bash
# Real git accepts -C <dir> before the subcommand; strip it like git does so
# argv patterns below match regardless of how the hook addresses the repo.
if [ "\$1" = "-C" ]; then shift 2; fi
case "\$*" in
  "log -1 --format=%ct") echo \$(( \$(date +%s) - (${age}) )) ;;
  "rev-parse --short HEAD") echo abc1234 ;;
  "log -1 --pretty=format:%s") echo "test commit" ;;
  "rev-parse --abbrev-ref HEAD") echo nh/feat/test ;;
  "diff --name-only HEAD~1..HEAD") echo foo.txt ;;
  "remote get-url origin") echo "${remote}" ;;
  "rev-parse --show-toplevel") echo "/tmp/mtf-builder" ;;
  "rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  *) echo "unexpected git argv: \$*" >&2; exit 99 ;;
esac
STUB
  chmod +x "${GIT_BIN_DIR}/git"
}

STATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-det-state-XXXXXX")"
run_hook() {
  rm -rf "${STATE_HOME:?}/claude-obsidian"
  PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null || true
}
# Same, but keeping state between calls, to exercise the sha dedup.
run_hook_keep_state() {
  PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null || true
}
# Negative cases must be silent AND clean-exit, not silent-because-crashed.
run_hook_strict() {
  local err rc
  err="$(mktemp)"
  PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || { rm -f "$err"; fail "hook exited $rc (expected 0)"; }
  [ -s "$err" ] && { local e; e="$(cat "$err")"; rm -f "$err"; fail "hook wrote to stderr: $e"; }
  rm -f "$err"
}

# --- 1. a QUIET commit is captured (no "[branch hash]" line anywhere) ---------
make_git_stub 0 "git@github.com:nhangen/test.git"
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
make_git_stub 4000 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' '{"tool_input":{"command":"git commit -q -F -"},"tool_response":{"stdout":""}}' | run_hook)"
[ -z "$OUT" ] || fail "stale HEAD was captured; the recency window is not enforced"$'\n'"got: $OUT"

# --- 4. non-commit Bash calls stay silent ------------------------------------
make_git_stub 0 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' '{"tool_input":{"command":"git status"},"tool_response":{"stdout":"nothing"}}' | run_hook)"
[ -z "$OUT" ] || fail "non-commit command produced output: $OUT"

OUT="$(printf '%s' '{"tool_input":{"command":"git commit --dry-run"},"tool_response":{"stdout":""}}' | run_hook)"
[ -z "$OUT" ] || fail "--dry-run was captured: $OUT"

OUT="$(printf '%s' '{"tool_input":{"command":"git commit -q"},"tool_response":{"stdout":"nothing to commit, working tree clean"}}' | run_hook)"
[ -z "$OUT" ] || fail "'nothing to commit' was captured: $OUT"


# --- 6. a FAILING commit right after a real one must not re-capture ----------
# The gate infers from git rather than confirming from output, so the guards and
# the sha check together have to reject these. A recent HEAD is present in all
# three; only the sha check / failure text stops them.
make_git_stub 0 "git@github.com:nhangen/test.git"
for payload in \
  '{"tool_input":{"command":"git commit -q -F -"},"tool_response":{"stdout":"","stderr":"husky - pre-commit hook exited with code 1"}}' \
  '{"tool_input":{"command":"git commit -q"},"tool_response":{"stdout":"","stderr":"fatal: cannot do a partial commit during a merge."}}' \
  '{"tool_input":{"command":"git commit -q -a"},"tool_response":{"stdout":"","stderr":"error: gpg failed to sign the data"}}' ; do
  OUT="$(printf '%s' "$payload" | run_hook)"
  [ -z "$OUT" ] || fail "failed commit was captured"$'\n'"payload: $payload"$'\n'"got: $OUT"
done

# --- 7. merely MENTIONING git commit must not capture ------------------------
for payload in \
  '{"tool_input":{"command":"grep -rn \"git commit\" docs/"},"tool_response":{"stdout":"docs/x.md: run git commit"}}' \
  '{"tool_input":{"command":"echo \"run git commit later\""},"tool_response":{"stdout":"run git commit later"}}' \
  '{"tool_input":{"command":"git log --grep=\"git commit\""},"tool_response":{"stdout":"commit abc"}}' ; do
  OUT="$(printf '%s' "$payload" | run_hook)"
  [ -z "$OUT" ] || fail "a mention of git commit was captured"$'\n'"payload: $payload"$'\n'"got: $OUT"
done

# --- 8. the same commit is captured once, not twice --------------------------
make_git_stub 0 "git@github.com:nhangen/test.git"
rm -rf "${STATE_HOME:?}/claude-obsidian"
FIRST="$(printf '%s' '{"tool_input":{"command":"git commit -q -F -"},"tool_response":{"stdout":""}}' | run_hook_keep_state)"
case "$FIRST" in *hash=*) : ;; *) fail "first capture missing"$'\n'"got: ${FIRST:-<empty>}" ;; esac
# A second REAL commit invocation on the same sha — e.g. `git commit --amend`
# that changed nothing, or the hook firing twice for one Bash call. Only the sha
# check can reject this; the command-word gate cannot.
SECOND="$(printf '%s' '{"tool_input":{"command":"git commit -q --amend --no-edit"},"tool_response":{"stdout":""}}' | run_hook_keep_state)"
[ -z "$SECOND" ] || fail "same sha captured twice (sha dedup not enforced)"$'\n'"got: $SECOND"

# --- 9. recency boundary -----------------------------------------------------
PAYLOAD='{"tool_input":{"command":"git commit -q -F -"},"tool_response":{"stdout":""}}'
make_git_stub 60 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' "$PAYLOAD" | OBSIDIAN_COMMIT_RECENT_WINDOW=60 run_hook)"
case "$OUT" in *hash=*) : ;; *) fail "AGE == window must capture"$'\n'"got: ${OUT:-<empty>}" ;; esac
make_git_stub 61 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' "$PAYLOAD" | OBSIDIAN_COMMIT_RECENT_WINDOW=60 run_hook)"
[ -z "$OUT" ] || fail "AGE == window+1 must skip"$'\n'"got: $OUT"

# --- 10. a FUTURE HEAD is not evidence of a fresh commit --------------------
make_git_stub -4000 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' "$PAYLOAD" | run_hook)"
[ -z "$OUT" ] || fail "future-dated HEAD was captured (clock-skew clamp regression)"$'\n'"got: $OUT"

# --- 11. negative cases exit 0 and write nothing to stderr ------------------
make_git_stub 0 "git@github.com:nhangen/test.git"
printf '%s' '{"tool_input":{"command":"git status"},"tool_response":{"stdout":"x"}}' | run_hook_strict

# --- 5. org/repo derivation across remote forms ------------------------------
check_org_repo() {
  local remote="$1" expect="$2" out
  make_git_stub 0 "$remote"
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
check_org_repo "ssh://git@gitlab.com:2222/altamira2/mtf-builder.git" "altamira2/mtf-builder"
check_org_repo "https://gitlab.com/altamira2/mtf-builder/"    "altamira2/mtf-builder"
check_org_repo "https://user@gitlab.com/org/repo.git"         "org/repo"
check_org_repo "https://oauth2:ghp_SECRET@gitlab.com:8443/org/repo.git" "org/repo"
# No port: without the userinfo strip this yields ghp_SECRET@gitlab.com/org/repo,
# putting the token in stdout and in a synced note's `repo:` frontmatter.
check_org_repo "https://oauth2:ghp_SECRET@gitlab.com/org/repo.git" "org/repo"
check_org_repo "https://host:8443/org/repo.git"               "org/repo"
check_org_repo "file:///srv/git/repo.git"                     "local/mtf-builder"
check_org_repo "/srv/git/bare-repo"                           "local/mtf-builder"

printf 'ok   commit-capture-detection.sh (quiet commits + host-agnostic org/repo)\n'
