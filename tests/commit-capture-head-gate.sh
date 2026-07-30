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
  [ -n "${ISOLATED_XDG:-}" ] && rm -rf "$ISOLATED_XDG"
  return 0
}
trap cleanup EXIT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-gate-XXXXXX")"
STATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-gate-state-XXXXXX")"
SNAP_DIR="${STATE_HOME}/claude-obsidian/pre-commit-head"

# The hook resolves its config through $OBSIDIAN_LOCAL_MD, then the XDG path, then
# the plugin dir. Left alone, every positive assertion here would depend on the
# developer having a real vault configured — the suite passed on this machine and
# failed on a fresh clone. Point config resolution at the plugin's own example and
# a scratch XDG home, the same isolation commit-capture-vault-path.sh uses.
ISOLATED_XDG="$(mktemp -d "${TMPDIR:-/tmp}/cc-gate-xdg-XXXXXX")"
export XDG_CONFIG_HOME="$ISOLATED_XDG"
mkdir -p "${ISOLATED_XDG}/claude-obsidian"
printf -- '---\nvault_path: %s/vault\n---\n' "$WORK" > "${ISOLATED_XDG}/claude-obsidian/obsidian.local.md"
unset OBSIDIAN_LOCAL_MD

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
# The retired guard read the tool *response*, and a subject supplied via `-F -`
# never reaches the payload at all — so a row whose only guard word is in the
# subject cannot fail however the hook behaves. Put the word where the old code
# looked: in the response, or in the command via `-m`.
for pair in \
  'git commit -q -m "fix: swallow fatal: on rebase"|' \
  'git commit -q -m "chore: explain nothing to commit"|' \
  'git commit -q -F -|Untracked files:' \
  'git commit -q -F -|nothing to commit, working tree clean' \
  'git commit -q -F -|fatal: cannot do a partial commit during a merge' ; do
  cmd="${pair%%|*}"
  resp="${pair#*|}"
  reset_state
  P="$(payload "$cmd" "$REPO" call-3 "$resp")"
  run_pre "$P"
  commit_in "$REPO" "work $RANDOM"
  run_post_verbose "$P"
  case "$POST_OUT" in
    *hash=*) : ;;
    *) fail "a real commit was dropped over failure text (command: $cmd / response: $resp)"$'\n'"got: ${POST_OUT:-<empty>}" ;;
  esac
done

# --- 4. no snapshot is reported, not silently dropped -----------------------
# A hand-wired hook config carrying only the PostToolUse half would otherwise
# stop capturing with no visible cause.
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-4)"
commit_in "$REPO" "unsnapshotted work"
run_post_verbose "$P"
case "$POST_OUT" in
  *hash=*) fail "captured with no snapshot; the gate is not being enforced"$'\n'"got: $POST_OUT" ;;
esac
case "$POST_OUT" in
  *PreToolUse*) : ;;
  *) fail "a missing snapshot was not reported"$'\n'"got: ${POST_OUT:-<empty>}" ;;
esac

# --- 5. a snapshot answers for one invocation only --------------------------
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-5)"
run_pre "$P"
commit_in "$REPO" "once only"
run_post_verbose "$P"
case "$POST_OUT" in *hash=*) : ;; *) fail "first capture missing"$'\n'"got: ${POST_OUT:-<empty>}" ;; esac
run_post_verbose "$P"
case "$POST_OUT" in
  *hash=*) fail "the same commit was captured twice (snapshot not consumed)"$'\n'"got: $POST_OUT" ;;
esac

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
case "$POST_OUT" in
  *hash=*) fail "a snapshot from another repository was accepted as evidence"$'\n'"got: $POST_OUT" ;;
esac
# The two rejections have to be distinguishable: "register the hook" is misleading
# advice when the hook ran and the snapshot simply belongs to another repo.
case "$POST_OUT" in
  *'is about'*) : ;;
  *) fail "discarding a foreign snapshot was not reported, or reused the missing-snapshot message"$'\n'"got: ${POST_OUT:-<empty>}" ;;
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
  # From $WORK, like every other case: run from the checkout and the `$PWD`
  # fallback resolves the plugin repo, so the payload under test is not the thing
  # being exercised.
  ( cd "$WORK" && printf '%s' "$bad" | XDG_STATE_HOME="$STATE_HOME" bash "$PRE" >/dev/null 2>&1 ) \
    || fail "pre-hook exited non-zero on payload: ${bad:-<empty>}"
done

# --- 9b. a snapshot about no repository at all is not written ----------------
# `sha=unresolved` with no root and no named directory matched every repo and no
# HEAD: the post-hook could only fall back to "the tip looks recent, assume a
# commit", which is the inference this gate replaces. There is nothing to record.
reset_state
run_pre "$(payload 'git commit -q -m x' "$WORK" call-9b)"
[ ! -d "$SNAP_DIR" ] || [ -z "$(ls -A "$SNAP_DIR" 2>/dev/null)" ] \
  || fail "a snapshot was written for a call with no resolvable and no named repository"$'\n'"got: $(cat "$SNAP_DIR"/* 2>/dev/null)"

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
# `../../` from the snapshot dir lands in $STATE_HOME, not $WORK — the assertion has
# to watch the directory the escape can actually reach, or it can never fire.
ESCAPE_MARK="$STATE_HOME/escaped-write"
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

# --- 13. a repo that did not exist at pre-time is still captured -------------
# `git worktree add ../wt && cd ../wt && git commit` is this project's documented
# workflow, and `mkdir sub && cd sub && git init && git commit` is the same shape.
# The pre-hook cannot read a HEAD that isn't there yet, and resolution falls through
# to the SURROUNDING repo — so matching on the resolved root alone discarded the real
# commit as belonging to another repository. master captured both of these.
reset_state
OUTER="$WORK/outer"
mkrepo "$OUTER" "git@github.com:nhangen/outer.git"
commit_in "$OUTER" "outer seed"
P="$(payload "git worktree add ../outer-wt -b feat && cd ../outer-wt && git commit -q -m x" "$OUTER" call-13a)"
run_pre "$P"
git -C "$OUTER" worktree add -q "$WORK/outer-wt" -b feat
commit_in "$WORK/outer-wt" "worktree commit"
run_post_verbose "$P"
case "$POST_OUT" in
  *hash=*) : ;;
  *) fail "a commit in a worktree created during the call was dropped"$'\n'"got: ${POST_OUT:-<empty>}"$'\n'"stderr: $POST_ERR"$'\n'"stdout-err: $POST_OUT" ;;
esac

reset_state
P="$(payload "mkdir -p sub && cd sub && git init -q && git commit -q -m x" "$OUTER" call-13b)"
run_pre "$P"
mkrepo "$OUTER/sub" "git@github.com:nhangen/inner.git"
commit_in "$OUTER/sub" "inner first commit"
run_post_verbose "$P"
case "$POST_OUT" in
  *"org_repo=nhangen/inner"*) : ;;
  *) fail "a repo initialised inside another during the call was dropped or misattributed"$'\n'"got: ${POST_OUT:-<empty>}" ;;
esac

# --- 14. a commit that arrived over the wire is not ours ---------------------
# `git pull && git commit` where the commit fails leaves the PULLED tip. It is a
# fast-forward, so the tip moved and ancestry accepts it; only the committer
# identity separates it from a commit we made. The old wall-clock check passed it
# whenever the teammate's commit was less than two minutes old.
reset_state
UP="$WORK/upstream.git"
git init -q --bare "$UP"
THEIRS="$WORK/theirs"
mkrepo "$THEIRS" "$UP"
git -C "$THEIRS" config user.email teammate@example.com
git -C "$THEIRS" config user.name Teammate
# A shared base first: without it the teammate's commit is the root commit, the
# clone already has it, the pull moves nothing, and the case proves nothing about
# the committer check because the HEAD gate rejects it first.
commit_in "$THEIRS" "shared base"
git -C "$THEIRS" push -q origin HEAD:refs/heads/main

MINE="$WORK/mine"
git clone -q "$UP" "$MINE"
git -C "$MINE" config core.hooksPath /dev/null
git -C "$MINE" config commit.gpgsign false
git -C "$MINE" config user.email me@example.com
git -C "$MINE" config user.name Me

commit_in "$THEIRS" "teammate work"
git -C "$THEIRS" push -q origin HEAD:refs/heads/main

BEFORE_PULL="$(git -C "$MINE" rev-parse HEAD)"
P="$(payload 'git pull && git commit -q -m mine' "$MINE" call-14)"
run_pre "$P"
git -C "$MINE" pull -q --ff-only origin main
git -C "$MINE" remote set-url origin "git@github.com:nhangen/mine.git"
[ "$(git -C "$MINE" rev-parse HEAD)" != "$BEFORE_PULL" ] \
  || fail "case 14 fixture did not fast-forward; the case cannot exercise the committer check"
run_post_verbose "$P"
case "$POST_OUT" in
  *"msg=teammate work"*) fail "a pulled commit was captured as ours — the exact failure #60 names"$'\n'"got: $POST_OUT" ;;
  *hash=*) fail "something was captured for a call that committed nothing"$'\n'"got: $POST_OUT" ;;
esac

# --- 15. a slow call does not lose the commit it made -----------------------
# PostToolUse fires when the whole Bash call finishes, not when `git commit`
# returns. `git commit && npm test` outlived the 120s recency window and the note
# was discarded — a commit the gate had positively observed, dropped in silence.
reset_state
P="$(payload 'git commit -q -m x && sleep 300' "$REPO" call-15)"
run_pre "$P"
commit_in "$REPO" "committed then a long test run"
# The tip has to be OLDER than the window for this to mean anything — with a
# one-second window and a commit made in the same second, the old code passed too.
sleep 2
POST_OUT=""
POST_ERR=""
err="$(mktemp)"
POST_OUT="$( cd "$WORK" && printf '%s' "$P" | XDG_STATE_HOME="$STATE_HOME" OBSIDIAN_COMMIT_RECENT_WINDOW=1 bash "$POST" 2>"$err" )" || fail "post-hook exited non-zero"
POST_ERR="$(cat "$err")"; rm -f "$err"
case "$POST_OUT" in
  *hash=*) : ;;
  *) fail "the wall clock discarded a commit the HEAD gate observed"$'\n'"got: ${POST_OUT:-<empty>}" ;;
esac

# --- 16. an undo is not a commit --------------------------------------------
# `git reset --hard HEAD~1` moves HEAD without committing, and it lands exactly on
# the previous tip's parent — which ancestry alone accepts.
reset_state
P="$(payload 'git reset --hard HEAD~1 && git commit -q -m x' "$REPO" call-16)"
run_pre "$P"
git -C "$REPO" reset -q --hard HEAD~1
run_post_verbose "$P"
[ -z "$POST_OUT" ] || fail "a reset was captured as a commit"$'\n'"got: $POST_OUT"

# --- 17. every "not captured" line is on the channel the skill reads --------
# stdout is what a hook exiting 0 surfaces, and what the record itself uses. On
# stderr these diagnostics were indistinguishable from silence.
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-17)"
commit_in "$REPO" "unsnapshotted"
run_post_verbose "$P"
case "$POST_OUT" in
  *'not captured'*) : ;;
  *) fail "the no-snapshot diagnostic is not on stdout"$'\n'"stdout: ${POST_OUT:-<empty>}"$'\n'"stderr: ${POST_ERR:-<empty>}" ;;
esac
[ -z "$POST_ERR" ] || fail "diagnostics still going to stderr: $POST_ERR"
case "$POST_OUT" in
  *'hash='*) fail "a diagnostic was emitted in record form; the skill would file a note for it"$'\n'"got: $POST_OUT" ;;
esac

# --- 18. a call that made several commits says so ---------------------------
reset_state
P="$(payload 'git commit -q -m one && git commit -q -m two' "$REPO" call-18)"
run_pre "$P"
commit_in "$REPO" "commit one"
commit_in "$REPO" "commit two"
run_post_verbose "$P"
case "$POST_OUT" in
  *'partial —'*) : ;;
  *) fail "two commits in one call captured one and said nothing about the other"$'\n'"got: ${POST_OUT:-<empty>}" ;;
esac
case "$POST_OUT" in
  *'msg=commit two'*) : ;;
  *) fail "the tip commit was not the one captured"$'\n'"got: $POST_OUT" ;;
esac

# --- 19. a path or branch cannot inject a field ahead of a real one ---------
# `|` is legal in a filename and in a refname, and files=/branch= both precede
# org_repo= and vault_path= in a record the skill parses first-match.
reset_state
INJ="$WORK/inject-path"
mkrepo "$INJ" "git@github.com:nhangen/injpath.git"
commit_in "$INJ" "seed"
# No `/` — that would make it a nested path rather than one filename, which is why
# an earlier attempt at this case could not create the fixture at all. A single
# component is enough: the record is delimiter-separated, not path-separated.
BAD_FILE='a | org_repo=EVIL | vault_path=EVILVAULT | b.txt'
if : > "$INJ/$BAD_FILE" 2>/dev/null; then
  git -C "$INJ" add -A
  git -C "$INJ" commit -q -m "add a piped path"
  P="$(payload 'git commit -q -m x' "$INJ" call-19)"
  # Snapshot the tip's parent so the commit above reads as landing during the call.
  mkdir -p "$SNAP_DIR"
  printf 'sha=%s\nroot=%s\nintent=\n' "$(git -C "$INJ" rev-parse HEAD~1)" "$(git -C "$INJ" rev-parse --show-toplevel)" \
    > "${SNAP_DIR}/$( . "${ROOT_DIR}/scripts/lib/commit-capture-parse.sh"; cc_snapshot_key "$P" )"
  run_post_verbose "$P"
  case "$POST_OUT" in
    *hash=*) : ;;
    *) fail "the injection fixture was not captured at all"$'\n'"got: ${POST_OUT:-<empty>}" ;;
  esac
  # The invariant is that the FIRST occurrence of each field is the real one, so a
  # reader taking the first match cannot be steered. The injected text may survive
  # as text — it just cannot survive as a *field*, which means its delimiters are
  # gone.
  first_field() {
    printf '%s' "$1" | tr '|' '\n' | while IFS= read -r seg; do
      seg="${seg#"${seg%%[![:space:]]*}"}"
      case "$seg" in
        "$2="*) printf '%s' "${seg#"$2"=}"; return 0 ;;
      esac
    done
  }
  GOT="$(first_field "$POST_OUT" org_repo)"
  [ "${GOT% }" = "nhangen/injpath" ] || fail "a path steered the first org_repo field: '$GOT'"$'\n'"got: $POST_OUT"
  GOT="$(first_field "$POST_OUT" vault_path)"
  case "${GOT% }" in
    EVILVAULT) fail "a path steered the first vault_path field"$'\n'"got: $POST_OUT" ;;
    '') fail "no vault_path field in the record"$'\n'"got: $POST_OUT" ;;
  esac
else
  printf 'skip commit-capture-head-gate.sh case 19: filesystem refused a path containing |\n' >&2
fi

# --- 20. a wrapper rewritten in between the two halves ----------------------
# The real asymmetry from issue #73: RTK's PreToolUse hook returns `updatedInput`,
# so the pre-hook's payload says `git commit` and the post-hook's says
# `rtk git commit`. Both halves share cc_invokes_commit, and it has to answer the
# same for both texts or the snapshot is written and never read.
reset_state
P_PRE="$(payload 'git commit -q -m x' "$REPO" call-rtk)"
P_POST="$(payload 'rtk git commit -q -m x' "$REPO" call-rtk)"
run_pre "$P_PRE"
commit_in "$REPO" "work behind a wrapper"
run_post_verbose "$P_POST"
case "$POST_OUT" in
  *"org_repo=altamira2/mtf-builder"*) : ;;
  *) fail "a commit whose command was rewritten to 'rtk git' between pre and post was lost"$'\n'"got: ${POST_OUT:-<empty>}"$'\n'"stderr: $POST_ERR" ;;
esac
# And the snapshot must be consumed, not leaked until the daily sweep.
if [ -n "$(ls -A "${STATE_HOME}/claude-obsidian/pre-commit-head" 2>/dev/null)" ]; then
  fail "the snapshot survived a capture behind a wrapper"
fi

# --- 21. the record is delivered on the only channel Claude reads -------------
# `PostToolUse` plain stdout goes to the debug log, not the transcript: the docs
# list only UserPromptSubmit, UserPromptExpansion and SessionStart as the events
# whose bare stdout becomes context. On exit 0 the sole way to reach the model is
# hookSpecificOutput.additionalContext, which is inserted next to the tool result.
# Printing the record as bare text meant the gate worked and the skill never heard
# about it (issue #75).
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-21)"
run_pre "$P"
commit_in "$REPO" "delivered work"
run_post_verbose "$P"
python3 - "$POST_OUT" <<'EOF' || fail "the record was not delivered as PostToolUse additionalContext"$'\n'"got: ${POST_OUT:-<empty>}"
import json, sys
d = json.loads(sys.argv[1])
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "PostToolUse", h
ctx = h["additionalContext"]
assert "obsidian-commit-capture: hash=" in ctx, ctx
assert "org_repo=altamira2/mtf-builder" in ctx, ctx
EOF

# A diagnostic travels the same way — a "not captured" line printed as bare text
# is as invisible as the record was.
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-21b)"
commit_in "$REPO" "no snapshot for this one"
run_post_verbose "$P"
python3 - "$POST_OUT" <<'EOF' || fail "a diagnostic was not delivered as additionalContext"$'\n'"got: ${POST_OUT:-<empty>}"
import json, sys
d = json.loads(sys.argv[1])
assert "not captured" in d["hookSpecificOutput"]["additionalContext"]
EOF

# The payload is JSON now, so anything a commit author controls has to be escaped
# or the envelope is unparseable and the whole record is lost — a quote in a
# subject is not exotic.
reset_state
P="$(payload 'git commit -q -m x' "$REPO" call-21c)"
run_pre "$P"
commit_in "$REPO" 'fix "quoted" and \backslash\ and	tab'
run_post_verbose "$P"
python3 - "$POST_OUT" <<'EOF' || fail "a quoted/backslashed subject broke the JSON envelope"$'\n'"got: ${POST_OUT:-<empty>}"
import json, sys
d = json.loads(sys.argv[1])
ctx = d["hookSpecificOutput"]["additionalContext"]
assert 'fix "quoted"' in ctx, ctx
assert "backslash" in ctx, ctx
EOF

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
