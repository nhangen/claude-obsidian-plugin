#!/usr/bin/env bash
# Exercises scripts/commit-capture.sh's freshness check and its org/repo
# derivation, with git stubbed so HEAD's age and the remote URL are controlled
# exactly.
#
# Two regressions, both silent:
#   1. The gate required the "[branch hash]" summary line in the tool output.
#      `git commit -q` prints nothing, so every quiet commit was skipped and its
#      capture lost — 12 days of mtf-builder history, discovered 2026-07-28.
#   2. The derivation matched SSH and github.com only, so an HTTPS GitLab remote
#      fell through to local/<repo>. The same repo was captured under three
#      different org_repo values and its notes landed in three folders.
#
# Whether a commit landed is decided by the PreToolUse HEAD snapshot, which has
# its own suite (commit-capture-head-gate.sh). Here the snapshot is always a sha
# no HEAD can equal, so these cases isolate what happens *after* the gate opens.
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
  # The post-hook asks git what the HEAD move was: is the snapshot's sha an
  # ancestor, and did we commit it. Answer yes to both — these cases are about
  # what happens once the gate has opened.
  "merge-base --is-ancestor "*) exit 0 ;;
  "config user.email") echo tester@example.com ;;
  "log -1 --format=%ce") echo tester@example.com ;;
  "rev-list --count "*) echo 1 ;;
  *) echo "unexpected git argv: \$*" >&2; exit 99 ;;
esac
STUB
  chmod +x "${GIT_BIN_DIR}/git"
}

STATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-det-state-XXXXXX")"

# The post-hook captures only when a PreToolUse snapshot shows HEAD moved. These
# cases are about what happens once it has: the snapshot sha is one no HEAD can
# equal, and the root is the one the stub reports — a sha/root pair the real
# pre-hook could actually have written, so the fixture stays representable.
seed_snapshot() {
  local payload="$1" key
  key="$(
    . "${ROOT_DIR}/scripts/lib/commit-capture-parse.sh"
    cc_snapshot_key "$payload"
  )"
  mkdir -p "${STATE_HOME:?}/claude-obsidian/pre-commit-head"
  printf 'sha=%s\nroot=/tmp/mtf-builder\nintent=\n' "1111111111111111111111111111111111111111" \
    > "${STATE_HOME}/claude-obsidian/pre-commit-head/${key}"
}

# The other snapshot shape: the pre-hook found no repo to read (the call created it),
# so there is no before-image and freshness is the only signal left. `intent` is a
# directory that exists, which the stub resolves to the same toplevel the post-hook
# sees — that is what marks the snapshot as being about *this* repo.
seed_blind_snapshot() {
  local payload="$1" key
  key="$(
    . "${ROOT_DIR}/scripts/lib/commit-capture-parse.sh"
    cc_snapshot_key "$payload"
  )"
  mkdir -p "${STATE_HOME:?}/claude-obsidian/pre-commit-head"
  printf 'sha=unresolved\nroot=\nintent=%s\n' "$PWD" \
    > "${STATE_HOME}/claude-obsidian/pre-commit-head/${key}"
}

run_hook() {
  local payload="$1"
  rm -rf "${STATE_HOME:?}/claude-obsidian"
  seed_snapshot "$payload"
  printf '%s' "$payload" | PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null || true
}

run_hook_blind() {
  local payload="$1"
  rm -rf "${STATE_HOME:?}/claude-obsidian"
  seed_blind_snapshot "$payload"
  printf '%s' "$payload" | PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null || true
}

# Negative cases must be silent AND clean-exit, not silent-because-crashed.
run_hook_strict() {
  local payload="$1" err rc
  err="$(mktemp)"
  printf '%s' "$payload" | PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || { rm -f "$err"; fail "hook exited $rc (expected 0)"; }
  [ -s "$err" ] && { local e; e="$(cat "$err")"; rm -f "$err"; fail "hook wrote to stderr: $e"; }
  rm -f "$err"
}

QUIET='{"tool_input":{"command":"cd /repo && git commit -q -F -"},"tool_response":{"stdout":""}}'

# --- 1. a QUIET commit is captured (no "[branch hash]" line anywhere) ---------
make_git_stub 0 "git@github.com:nhangen/test.git"
OUT="$(run_hook "$QUIET")"
case "$OUT" in
  *hash=abc1234*) : ;;
  *) fail "quiet commit not captured (this is the -q regression)"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# --- 2. a non-quiet commit still works ---------------------------------------
OUT="$(run_hook '{"tool_input":{"command":"git commit -F -"},"tool_response":{"stdout":"[dev abc1234] test commit\n 1 file changed"}}')"
case "$OUT" in
  *hash=abc1234*) : ;;
  *) fail "non-quiet commit stopped being captured"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# --- 3. with no before-image, a stale HEAD is NOT captured -------------------
# When the repo did not exist at pre-time there is nothing to compare against, so
# freshness is the only thing separating a brand-new first commit from history that
# was already there. (With a real before-image the clock is not consulted: it used
# to discard commits whose Bash call simply kept running — see the head-gate suite.)
make_git_stub 4000 "git@github.com:nhangen/test.git"
OUT="$(run_hook_blind "$QUIET")"
[ -z "$OUT" ] || fail "stale HEAD was captured on the blind path; the recency window is not enforced"$'\n'"got: $OUT"

# --- 4. non-commit Bash calls stay silent ------------------------------------
make_git_stub 0 "git@github.com:nhangen/test.git"
OUT="$(run_hook '{"tool_input":{"command":"git status"},"tool_response":{"stdout":"nothing"}}')"
[ -z "$OUT" ] || fail "non-commit command produced output: $OUT"

# --- 5. recency boundary (blind path) ----------------------------------------
make_git_stub 60 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' "$QUIET" | { rm -rf "${STATE_HOME:?}/claude-obsidian"; seed_blind_snapshot "$QUIET"; PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" OBSIDIAN_COMMIT_RECENT_WINDOW=60 bash "$SCRIPT" 2>/dev/null; } || true)"
case "$OUT" in *hash=*) : ;; *) fail "AGE == window must capture"$'\n'"got: ${OUT:-<empty>}" ;; esac
make_git_stub 61 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' "$QUIET" | { rm -rf "${STATE_HOME:?}/claude-obsidian"; seed_blind_snapshot "$QUIET"; PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" OBSIDIAN_COMMIT_RECENT_WINDOW=60 bash "$SCRIPT" 2>/dev/null; } || true)"
[ -z "$OUT" ] || fail "AGE == window+1 must skip"$'\n'"got: $OUT"

# A trusted before-image is NOT subject to the clock: the same 4000s-old tip that
# case 3 rejects is captured here, because the snapshot proves the tip moved during
# this call. This is the `git commit && <slow thing>` loss.
make_git_stub 4000 "git@github.com:nhangen/test.git"
OUT="$(run_hook "$QUIET")"
case "$OUT" in *hash=*) : ;; *) fail "the clock still vetoes a commit the snapshot observed"$'\n'"got: ${OUT:-<empty>}" ;; esac

# --- 6. a FUTURE HEAD is not evidence of a fresh commit ---------------------
make_git_stub -4000 "git@github.com:nhangen/test.git"
OUT="$(run_hook "$QUIET")"
[ -z "$OUT" ] || fail "future-dated HEAD was captured (clock-skew clamp regression)"$'\n'"got: $OUT"

# --- 7. negative cases exit 0 and write nothing to stderr -------------------
make_git_stub 0 "git@github.com:nhangen/test.git"
run_hook_strict '{"tool_input":{"command":"git status"},"tool_response":{"stdout":"x"}}'

# --- 8. org/repo derivation across remote forms ------------------------------
check_org_repo() {
  local remote="$1" expect="$2" out
  make_git_stub 0 "$remote"
  out="$(run_hook "$QUIET")"
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
