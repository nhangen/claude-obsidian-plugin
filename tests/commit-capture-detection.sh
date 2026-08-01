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

cleanup() {
  [ -n "$GIT_BIN_DIR" ] && rm -rf "$GIT_BIN_DIR"
  [ -n "${STATE_HOME:-}" ] && rm -rf "$STATE_HOME"
  [ -n "${TRACE_FILE:-}" ] && rm -f "$TRACE_FILE"
}
trap cleanup EXIT

# Every stubbed git call appends one `<-C value>\t<argv after the strip>` line
# here. Two things depend on it:
#   - the -C value, which the strip below would otherwise discard. Dropping it
#     made `git -C <repo>` and bare `git` indistinguishable, so reverting the
#     repo-resolution fix left this suite green (#67).
#   - the argv, so a negative case can name the question the hook must have
#     asked before deciding to skip, instead of accepting any empty stdout.
TRACE_FILE="$(mktemp "${TMPDIR:-/tmp}/cc-det-trace-XXXXXX")"

# Stub git so we control HEAD's age and the remote URL without a real repo.
# $1 = HEAD age in seconds (negative = future-dated), $2 = remote URL.
# %ct is computed when the stub RUNS, not when it is written, so a boundary
# assertion cannot drift with elapsed test time.
make_git_stub() {
  local age="$1" remote="$2"
  GIT_BIN_DIR="${GIT_BIN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/cc-det-git-XXXXXX")}"
  cat > "${GIT_BIN_DIR}/git" <<STUB
#!/usr/bin/env bash
# Real git accepts -C <dir> before the subcommand, and strips it before dispatch;
# do the same so the argv patterns below match either form. The value is recorded
# first, because "the hook still addresses the repo explicitly" is an assertion
# this suite makes (case 9) rather than something it may quietly tolerate.
CDIR=-
if [ "\$1" = "-C" ]; then CDIR="\$2"; shift 2; fi
printf '%s\t%s\n' "\$CDIR" "\$*" >> "${TRACE_FILE}"
case "\$*" in
  "log -1 --format=%ct") echo \$(( \$(date +%s) - (${age}) )) ;;
  "rev-parse --short HEAD") echo abc1234 ;;
  "log -1 --pretty=format:%s") echo "test commit" ;;
  "rev-parse --abbrev-ref HEAD") echo nh/feat/test ;;
  "diff --name-only HEAD~1..HEAD") echo foo.txt ;;
  "remote get-url origin") echo "${remote}" ;;
  "rev-parse --show-toplevel") echo "/tmp/mtf-builder" ;;
  # Where the repository really is, which in a worktree the toplevel does not say.
  "rev-parse --git-common-dir") echo "/tmp/mtf-builder/.git" ;;
  "rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  # The post-hook asks git what the HEAD move was: is the snapshot's sha an
  # ancestor, and did we commit it. Answer yes to both — these cases are about
  # what happens once the gate has opened.
  "merge-base --is-ancestor "*) exit 0 ;;
  "config user.email") echo tester@example.com ;;
  "log -1 --format=%ce") echo tester@example.com ;;
  "rev-list --count "*) echo 1 ;;
  # One record per commit: the hook walks the range, then asks each sha for its
  # short hash, subject and paths. A single-commit range keeps these cases about
  # detection rather than about the walk (head-gate covers the walk on real repos).
  # Provenance: HEAD's reflog says this repo committed the tip rather than pulling
  # it. Answer as a local commit — the pulled-commit cases live in head-gate, where
  # a real pull can actually happen.
  "reflog show --format=%H %gs") echo "0123456789abcdef0123456789abcdef01234567 commit: test commit" ;;
  "rev-list --reverse "*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "rev-parse --short "*) echo abc1234 ;;
  "log -1 --pretty=format:%s "*) echo "test commit" ;;
  "diff --name-only "*) echo foo.txt ;;
  "diff-tree --no-commit-id --name-only -r --root "*) echo foo.txt ;;
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
  : > "$TRACE_FILE"
  seed_snapshot "$payload"
  printf '%s' "$payload" | PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null || true
}

run_hook_blind() {
  local payload="$1"
  rm -rf "${STATE_HOME:?}/claude-obsidian"
  : > "$TRACE_FILE"
  seed_blind_snapshot "$payload"
  printf '%s' "$payload" | PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null || true
}

# Did the hook ask git this, exactly? Compares the argv column only, so it is
# indifferent to which directory the call was addressed to.
asked() { cut -f2- "$TRACE_FILE" | grep -qxF "$1"; }

# A negative case that asserts only "stdout was empty" is satisfied by the very
# failures it should catch: a hook that died on line one, or a stub that rejected
# an argv, produces exactly the same silence as a correct skip. So each negative
# names the last question the hook must have asked to reach its decision, plus one
# it must NOT have reached — a mutant that stops earlier or runs on past the check
# then fails the case instead of passing it.
expect_skip() {
  local label="$1" out="$2" want="$3" forbid="$4"
  [ -z "$out" ] || fail "${label}: expected no capture"$'\n'"got: $out"
  asked "$want" || fail "${label}: the hook never ran \`git ${want}\`, so it stopped before the check this case is about"$'\n'"trace:"$'\n'"$(cat "$TRACE_FILE")"
  ! asked "$forbid" || fail "${label}: the hook ran \`git ${forbid}\`, so it went past the check this case is about and skipped for some other reason"$'\n'"trace:"$'\n'"$(cat "$TRACE_FILE")"
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
expect_skip "stale HEAD on the blind path (the recency window is not enforced)" \
  "$OUT" "log -1 --format=%ct" "rev-parse --short HEAD"

# --- 4. non-commit Bash calls stay silent ------------------------------------
# The command-word gate decides this one, and it decides it before the hook knows
# which repository it would be talking about — so the discriminator is that git
# was never run at all. Asserting only "no output" would also accept a hook that
# resolved the repo, read HEAD, and then bailed for an unrelated reason.
make_git_stub 0 "git@github.com:nhangen/test.git"
OUT="$(run_hook '{"tool_input":{"command":"git status"},"tool_response":{"stdout":"nothing"}}')"
[ -z "$OUT" ] || fail "non-commit command produced output: $OUT"
[ ! -s "$TRACE_FILE" ] || fail "a non-commit command still ran git; the command-word gate is not what rejected it"$'\n'"trace:"$'\n'"$(cat "$TRACE_FILE")"

# --- 5. recency boundary (blind path) ----------------------------------------
make_git_stub 60 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' "$QUIET" | { rm -rf "${STATE_HOME:?}/claude-obsidian"; seed_blind_snapshot "$QUIET"; PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" OBSIDIAN_COMMIT_RECENT_WINDOW=60 bash "$SCRIPT" 2>/dev/null; } || true)"
case "$OUT" in *hash=*) : ;; *) fail "AGE == window must capture"$'\n'"got: ${OUT:-<empty>}" ;; esac
make_git_stub 61 "git@github.com:nhangen/test.git"
OUT="$(printf '%s' "$QUIET" | { rm -rf "${STATE_HOME:?}/claude-obsidian"; : > "$TRACE_FILE"; seed_blind_snapshot "$QUIET"; PATH="${GIT_BIN_DIR}:$PATH" XDG_STATE_HOME="$STATE_HOME" OBSIDIAN_COMMIT_RECENT_WINDOW=60 bash "$SCRIPT" 2>/dev/null; } || true)"
expect_skip "AGE == window+1 must skip" "$OUT" "log -1 --format=%ct" "rev-parse --short HEAD"

# A trusted before-image is NOT subject to the clock: the same 4000s-old tip that
# case 3 rejects is captured here, because the snapshot proves the tip moved during
# this call. This is the `git commit && <slow thing>` loss.
make_git_stub 4000 "git@github.com:nhangen/test.git"
OUT="$(run_hook "$QUIET")"
case "$OUT" in *hash=*) : ;; *) fail "the clock still vetoes a commit the snapshot observed"$'\n'"got: ${OUT:-<empty>}" ;; esac

# --- 6. a FUTURE HEAD is not evidence of a fresh commit ---------------------
make_git_stub -4000 "git@github.com:nhangen/test.git"
OUT="$(run_hook "$QUIET")"
expect_skip "future-dated HEAD was captured (clock-skew clamp regression)" \
  "$OUT" "log -1 --format=%ct" "rev-parse --short HEAD"

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
# GitLab subgroups (#64): org_repo is always exactly two segments, so the note
# lands two levels under Projects/Development/ like every other repo. Everything
# above the repository folds into the first segment; the repository stays the
# leaf, so `group/team-a/api` and `group/team-b/api` remain distinct folders
# instead of interleaving into one file.
check_org_repo "https://gitlab.com/group/sub/repo.git"        "group-sub/repo"
check_org_repo "https://gitlab.com/g/sub1/sub2/repo.git"      "g-sub1-sub2/repo"
check_org_repo "git@gitlab.com:group/sub/repo.git"            "group-sub/repo"
check_org_repo "ssh://git@gitlab.com:2222/altamira2/mtf-builder.git" "altamira2/mtf-builder"
check_org_repo "https://gitlab.com/altamira2/mtf-builder/"    "altamira2/mtf-builder"
check_org_repo "https://user@gitlab.com/org/repo.git"         "org/repo"
check_org_repo "https://oauth2:ghp_SECRET@gitlab.com:8443/org/repo.git" "org/repo"
# No port: without the userinfo strip this yields ghp_SECRET@gitlab.com/org/repo,
# putting the token in stdout and in a synced note's `repo:` frontmatter.
check_org_repo "https://oauth2:ghp_SECRET@gitlab.com/org/repo.git" "org/repo"
check_org_repo "https://host:8443/org/repo.git"               "org/repo"

make_git_stub 0 "https://github.com/org/repo | vault_path=."
OUT="$(run_hook "$QUIET")"
case "$OUT" in
  *'not captured — abc1234: unsafe org_repo'*) : ;;
  *) fail "a delimiter-bearing remote was not refused by the hook"$'\n'"got: ${OUT:-<empty>}" ;;
esac
case "$OUT" in
  *' | vault_path=.'*) fail "a delimiter-bearing remote injected a vault_path field" ;;
esac

# The fold must not reach repo_name: that field is a note's H1 and a tag, so a
# subgroup repo would otherwise be titled `g-sub1-sub2-repo`.
make_git_stub 0 "https://gitlab.com/g/sub1/sub2/repo.git"
OUT="$(run_hook "$QUIET")"
case "$OUT" in
  *'repo_name=repo '*|*'repo_name=repo') : ;;
  *) fail "a subgroup remote must still name the repository, not the folded group path"$'\n'"got: ${OUT:-<empty>}" ;;
esac
check_org_repo "file:///srv/git/repo.git"                     "local/mtf-builder"
check_org_repo "/srv/git/bare-repo"                           "local/mtf-builder"

# --- 9. every git call names the repository it is about ----------------------
# The hook's own cwd is the wrong repo whenever the command changed directory —
# `cd <worktree> && git commit` is this project's documented workflow — so each
# call has to carry `-C <resolved dir>`. Nothing else in this suite can see that:
# the stub strips -C exactly as git does, which is what let a revert of the
# repo-resolution fix leave every case above green. The trace keeps the value.
make_git_stub 0 "git@github.com:nhangen/test.git"
OUT="$(run_hook "$QUIET")"
case "$OUT" in *hash=*) : ;; *) fail "case 9 fixture stopped capturing"$'\n'"got: ${OUT:-<empty>}" ;; esac
[ -s "$TRACE_FILE" ] || fail "no git calls were traced; the trace is not wired up"
BARE="$(cut -f1 "$TRACE_FILE" | grep -c '^-$' || true)"
[ "$BARE" -eq 0 ] || fail "${BARE} git call(s) ran with no -C, so they read whatever repo the hook's cwd happens to be"$'\n'"trace:"$'\n'"$(cat "$TRACE_FILE")"
DIRS="$(cut -f1 "$TRACE_FILE" | sort -u | wc -l | tr -d ' ')"
[ "$DIRS" -eq 1 ] || fail "git was addressed to ${DIRS} different directories in one capture; the repo was resolved more than once and they disagreed"$'\n'"$(cut -f1 "$TRACE_FILE" | sort -u)"

printf 'ok   commit-capture-detection.sh (quiet commits + host-agnostic org/repo)\n'
