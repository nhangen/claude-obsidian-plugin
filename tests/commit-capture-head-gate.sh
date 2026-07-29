#!/usr/bin/env bash
# Exercises the PreToolUse/PostToolUse pair that decides whether a commit landed.
#
# The old post-hook inferred it from the command text plus a tip that was recent
# and not yet seen. Nothing tied HEAD to the invocation being observed, so after
# any dropped capture a *failed* commit picked up its predecessor and filed it
# with the hook's clock instead of the commit's. `false && git commit` reproduced
# that end to end during the PR #48 review.
#
# The pair below observes the thing that matters: HEAD before the call, HEAD
# after. Real git repositories throughout — a stub cannot make a commit land.
#
# Every case was verified to fail against the text-guard version.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POST="${ROOT_DIR}/scripts/commit-capture.sh"
PRE="${ROOT_DIR}/scripts/commit-capture-pre.sh"

WORK=""
STATE_HOME=""
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$STATE_HOME" ] && rm -rf "$STATE_HOME"
  return 0
}
trap cleanup EXIT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-gate-XXXXXX")"
STATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-gate-state-XXXXXX")"
SNAP_DIR="${STATE_HOME}/claude-obsidian/pre-commit-head"

mkrepo() {
  local dir="$1" remote="${2:-git@github.com:nhangen/gate.git}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  # Fixtures must not run the developer's global hooks (an identity gate lives
  # there and would block every seed commit).
  git -C "$dir" config core.hooksPath /dev/null
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Tester
  git -C "$dir" remote add origin "$remote"
}

commit_in() {
  local dir="$1" subject="$2" file
  file="f$RANDOM.txt"
  : > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -q -m "$subject"
}

# $1 = command, $2 = cwd, $3 = tool_use_id (optional), $4 = response text
payload() {
  local cmd="$1" cwd="${2:-}" id="${3:-}" resp="${4:-}" esc="$1"
  esc="${esc//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\n'/\\n}"
  printf '{'
  [ -n "$id" ] && printf '"tool_use_id":"%s",' "$id"
  [ -n "$cwd" ] && printf '"cwd":"%s",' "$cwd"
  printf '"session_id":"sess-1","tool_input":{"command":"%s"},"tool_response":{"stdout":"%s"}}' "$esc" "$resp"
}

# Both hooks run from a directory that is NOT a repository, so the last-resort
# `$PWD` candidate never resolves and a case that means to exercise "no repo
# here" cannot accidentally pick up the checkout the suite runs in.
run_pre() {
  local rc=0
  ( cd "$WORK" && printf '%s' "$1" | XDG_STATE_HOME="$STATE_HOME" bash "$PRE" ) || rc=$?
  [ "$rc" -eq 0 ] || fail "pre-hook exited $rc — a non-zero PreToolUse hook blocks the Bash call"
}
# Post with stderr captured; sets POST_OUT and POST_ERR.
run_post_verbose() {
  local err rc=0
  err="$(mktemp)"
  POST_OUT="$( cd "$WORK" && printf '%s' "$1" | XDG_STATE_HOME="$STATE_HOME" bash "$POST" 2>"$err" )" || rc=$?
  POST_ERR="$(cat "$err")"
  rm -f "$err"
  [ "$rc" -eq 0 ] || fail "post-hook exited $rc (expected 0)"
}

reset_state() { rm -rf "${STATE_HOME:?}/claude-obsidian"; }

REPO="$WORK/repo"
mkrepo "$REPO" "https://gitlab.com/altamira2/mtf-builder.git"
commit_in "$REPO" "seed commit"

# --- 1. a commit that lands between pre and post is captured -----------------
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-1)"
run_pre "$P"
commit_in "$REPO" "real work"
run_post_verbose "$P"
case "$POST_OUT" in
  *"org_repo=altamira2/mtf-builder"*) : ;;
  *) fail "a commit that landed during the call was not captured"$'\n'"got: ${POST_OUT:-<empty>}"$'\n'"stderr: $POST_ERR" ;;
esac
[ -z "$POST_ERR" ] || fail "a successful capture wrote to stderr: $POST_ERR"

# --- 2. HEAD unchanged means nothing landed, whatever the text says ----------
# Each of these fired a real `git commit` that committed nothing, or none at all.
# The text guards needed a phrase per failure mode; `false && git commit` had no
# phrase at all and read as success.
for cmd in \
  'git commit -q -m x' \
  'false && git commit -q -m x' \
  'git commit --dry-run' \
  'git commit -q -m "add --dry-run flag"' ; do
  reset_state
  P="$(payload "$cmd" "$REPO" call-2)"
  run_pre "$P"
  run_post_verbose "$P"
  [ -z "$POST_OUT" ] || fail "HEAD did not move but the call was captured: $cmd"$'\n'"got: $POST_OUT"
  [ -z "$POST_ERR" ] || fail "a legitimate no-capture wrote to stderr: $cmd"$'\n'"got: $POST_ERR"
done

# --- 3. failure phrases no longer suppress a real capture -------------------
# A commit subject or tool output containing `fatal:`, `error:`, or
# `Untracked files:` used to be read as a failed commit and dropped.
for pair in \
  'fix: swallow fatal: on rebase|' \
  'chore: nothing to commit yet|' \
  'feat: add --dry-run flag|Untracked files:' \
  'fix: error: prefix|nothing to commit, working tree clean' ; do
  subject="${pair%%|*}"
  resp="${pair#*|}"
  reset_state
  P="$(payload 'git commit -q -F -' "$REPO" call-3 "$resp")"
  run_pre "$P"
  commit_in "$REPO" "$subject"
  run_post_verbose "$P"
  case "$POST_OUT" in
    *hash=*) : ;;
    *) fail "a real commit was dropped over failure text (subject: $subject / response: $resp)"$'\n'"got: ${POST_OUT:-<empty>}" ;;
  esac
done

# --- 4. no snapshot is reported, not silently dropped -----------------------
# A hand-wired hook config carrying only the PostToolUse half would otherwise
# stop capturing with no visible cause.
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-4)"
commit_in "$REPO" "unsnapshotted work"
run_post_verbose "$P"
[ -z "$POST_OUT" ] || fail "captured with no snapshot; the gate is not being enforced"$'\n'"got: $POST_OUT"
case "$POST_ERR" in
  *PreToolUse*) : ;;
  *) fail "a missing snapshot was not reported on stderr"$'\n'"got: ${POST_ERR:-<empty>}" ;;
esac

# --- 5. a snapshot answers for one invocation only --------------------------
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-5)"
run_pre "$P"
commit_in "$REPO" "once only"
run_post_verbose "$P"
case "$POST_OUT" in *hash=*) : ;; *) fail "first capture missing"$'\n'"got: ${POST_OUT:-<empty>}" ;; esac
run_post_verbose "$P"
[ -z "$POST_OUT" ] || fail "the same commit was captured twice (snapshot not consumed)"$'\n'"got: $POST_OUT"

# --- 6. the first commit in a repo with no history is captured --------------
# HEAD is unborn before the call, so there is no sha to compare — `none` still
# differs from whatever the commit produces.
reset_state
FRESH="$WORK/fresh"
mkrepo "$FRESH" "git@github.com:nhangen/fresh.git"
P="$(payload 'git commit -q -m first' "$FRESH" call-6)"
run_pre "$P"
grep -q '^sha=none$' "$SNAP_DIR"/* || fail "an unborn HEAD was not recorded as 'none'"$'\n'"got: $(cat "$SNAP_DIR"/*)"
commit_in "$FRESH" "first commit"
run_post_verbose "$P"
case "$POST_OUT" in
  *"org_repo=nhangen/fresh"*) : ;;
  *) fail "a repo's first commit was not captured"$'\n'"got: ${POST_OUT:-<empty>}"$'\n'"stderr: $POST_ERR" ;;
esac

# --- 7. a repo that does not exist yet is recorded as unresolved ------------
# `mkdir x && cd x && git init && git commit` is a real shape: the pre-hook has
# no repo to read. The post-hook then has no prior HEAD and falls back to
# requiring a freshly-dated tip, which a brand-new commit satisfies.
reset_state
LATE="$WORK/late"
P="$(payload "mkdir -p $LATE && cd $LATE && git init -q && git commit -q -m x" "$WORK" call-7)"
run_pre "$P"
grep -q '^sha=unresolved$' "$SNAP_DIR"/* || fail "an unresolvable repo was not recorded as 'unresolved'"$'\n'"got: $(cat "$SNAP_DIR"/*)"
mkrepo "$LATE" "git@github.com:nhangen/late.git"
commit_in "$LATE" "late init"
run_post_verbose "$P"
case "$POST_OUT" in
  *"org_repo=nhangen/late"*) : ;;
  *) fail "a repo created during the call was not captured"$'\n'"got: ${POST_OUT:-<empty>}"$'\n'"stderr: $POST_ERR" ;;
esac

# --- 8. a snapshot from another repository is not evidence about this one ----
# Without a tool_use_id the key is session-scoped, so two concurrent commits in
# one session can cross. The other repo's sha is unequal to this HEAD whether or
# not anything was committed here, so reusing it is the "recent tip, assume a
# commit" inference this gate removes. This repo's tip is deliberately FRESH:
# only the recorded root can reject it, the freshness check cannot.
reset_state
SIBLING="$WORK/sibling"
mkrepo "$SIBLING" "git@github.com:nhangen/sibling.git"
commit_in "$SIBLING" "fresh tip, committed before the call"
OTHER_P="$(payload 'git commit -q -m x' "$REPO")"
run_pre "$OTHER_P"                       # snapshot belongs to $REPO
MINE_P="$(payload 'git commit -q -m x' "$SIBLING")"
run_post_verbose "$MINE_P"               # same session key, different repo
[ -z "$POST_OUT" ] || fail "a snapshot from another repository was accepted as evidence"$'\n'"got: $POST_OUT"
case "$POST_ERR" in
  *PreToolUse*) : ;;
  *) fail "discarding a foreign snapshot was not reported on stderr"$'\n'"got: ${POST_ERR:-<empty>}" ;;
esac

# --- 9. the pre-hook is silent, exits 0, and only snapshots commit calls -----
reset_state
for cmd in 'git status' 'echo "git commit"' 'grep -rn commit .' ; do
  P="$(payload "$cmd" "$REPO" "call-9")"
  ERR="$(mktemp)"
  RC=0
  OUT="$( cd "$WORK" && printf '%s' "$P" | XDG_STATE_HOME="$STATE_HOME" bash "$PRE" 2>"$ERR" )" || RC=$?
  E="$(cat "$ERR")"; rm -f "$ERR"
  [ "$RC" -eq 0 ] || fail "pre-hook exited $RC on '$cmd' — a non-zero PreToolUse hook blocks the Bash call"
  [ -z "$OUT" ] || fail "pre-hook wrote to stdout on '$cmd': $OUT"
  [ -z "$E" ] || fail "pre-hook wrote to stderr on '$cmd': $E"
  [ ! -d "$SNAP_DIR" ] || [ -z "$(ls -A "$SNAP_DIR" 2>/dev/null)" ] \
    || fail "pre-hook snapshotted a call that does not invoke git commit: $cmd"
done

# Malformed and hostile payloads must not fail the tool call either.
for bad in '' 'not json at all' '{"tool_input":{"command":"git commit -q -m x"}}' \
           '{"cwd":"/nonexistent/nope","tool_input":{"command":"cd /nonexistent/nope && git commit"}}' ; do
  printf '%s' "$bad" | XDG_STATE_HOME="$STATE_HOME" bash "$PRE" >/dev/null 2>&1 \
    || fail "pre-hook exited non-zero on payload: ${bad:-<empty>}"
done

# --- 10. abandoned snapshots are swept -------------------------------------
# One is left behind whenever the tool call never completes (denied, interrupted,
# session killed). Nothing else deletes them.
reset_state
mkdir -p "$SNAP_DIR"
printf 'sha=deadbeef\nroot=\n' > "${SNAP_DIR}/stale-key"
touch -t 200001010000 "${SNAP_DIR}/stale-key"
printf 'sha=deadbeef\nroot=\n' > "${SNAP_DIR}/fresh-key"
run_pre "$(payload 'git commit -q -m x' "$REPO" call-10)"
[ ! -f "${SNAP_DIR}/stale-key" ] || fail "an abandoned snapshot was not swept"
[ -f "${SNAP_DIR}/fresh-key" ] || fail "the sweep deleted a current snapshot"

# --- 11. concurrent calls do not cross when the payload carries an id -------
reset_state
A="$WORK/repo-a"; B="$WORK/repo-b"
mkrepo "$A" "git@github.com:nhangen/aaa.git"; commit_in "$A" "a seed"
mkrepo "$B" "git@github.com:nhangen/bbb.git"; commit_in "$B" "b seed"
PA="$(payload 'git commit -q -m x' "$A" tool-a)"
PB="$(payload 'git commit -q -m x' "$B" tool-b)"
run_pre "$PA"
run_pre "$PB"
commit_in "$A" "only A commits"
run_post_verbose "$PA"
case "$POST_OUT" in
  *"org_repo=nhangen/aaa"*) : ;;
  *) fail "the repo that committed was not captured"$'\n'"got: ${POST_OUT:-<empty>}" ;;
esac
run_post_verbose "$PB"
[ -z "$POST_OUT" ] || fail "the idle repo was captured off its sibling's commit"$'\n'"got: $POST_OUT"

# --- 12. the key is a digest, so an id from the payload cannot steer the write --
# tool_use_id arrives from outside. Used raw as a filename, one containing `/`
# writes outside the snapshot directory and a long one exceeds NAME_MAX — where
# the open fails and the whole gate silently stops working.
reset_state
ESCAPE_MARK="$WORK/escaped-write"
LONG_ID="$(printf 'i%.0s' $(seq 1 400))"
for id in "../../$(basename "$ESCAPE_MARK")" "$LONG_ID" ; do
  reset_state
  P="$(payload 'git commit -q -m x' "$REPO" "$id")"
  run_pre "$P"
  COUNT=$(find "$SNAP_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$COUNT" -eq 1 ] || fail "a hostile tool_use_id produced $COUNT snapshot files (want 1)"
  [ ! -e "$ESCAPE_MARK" ] || fail "a tool_use_id containing '..' wrote outside the snapshot directory"
  commit_in "$REPO" "hostile id $RANDOM"
  run_post_verbose "$P"
  case "$POST_OUT" in
    *hash=*) : ;;
    *) fail "a commit was dropped because the snapshot key came from a hostile id"$'\n'"got: ${POST_OUT:-<empty>}"$'\n'"stderr: $POST_ERR" ;;
  esac
done

# --- wiring: both halves are registered on Bash ------------------------------
# The pair is one mechanism. Shipping the post-hook without the pre-hook turns
# every capture into a stderr diagnostic.
HJ="${ROOT_DIR}/hooks/hooks.json"
python3 -c "
import json
h = json.load(open('$HJ'))['hooks']
for event, script in (('PreToolUse', 'commit-capture-pre.sh'), ('PostToolUse', 'commit-capture.sh')):
    assert event in h, event + ' not registered'
    groups = [g for g in h[event] if g.get('matcher') == 'Bash']
    assert groups, event + ' has no Bash matcher'
    cmds = [hk['command'] for g in groups for hk in g['hooks']]
    assert any(script in c for c in cmds), (event, script, cmds)
" || fail "hooks.json does not register both commit-capture halves on Bash"

printf 'ok   commit-capture-head-gate.sh (PreToolUse HEAD snapshot decides capture)\n'
