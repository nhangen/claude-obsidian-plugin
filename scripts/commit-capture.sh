#!/usr/bin/env bash
# commit-capture.sh
# PostToolUse command hook. Detects git commits from Bash tool calls, extracts
# metadata, and outputs it inline. Non-commit Bash calls exit silently.
#
# "A commit happened" is decided by comparing HEAD against the snapshot its
# PreToolUse sibling (commit-capture-pre.sh) took before the call ran. Reading
# success out of the command text and the tool output could not do that job: the
# guard list had to grow a phrase for every way git can fail, `--dry-run` had to
# be told apart from a commit message that mentions the flag, `false && git
# commit` still read as success, and a failed commit inherited its predecessor's
# tip. None of that survives a HEAD comparison, so none of it is here any more.

set -uo pipefail

INPUT=$(cat)

# --- Quick exit for non-commit commands ---

case "$INPUT" in
  *'"command"'*commit*) ;;
  *) exit 0 ;;
esac

# Everything this hook has to say — the record and every "not captured" line —
# leaves through `hookSpecificOutput.additionalContext`, because that is the only
# channel a PostToolUse hook has on exit 0. Bare stdout goes to the debug log and
# not the transcript; the documented exceptions whose plain stdout becomes context
# are UserPromptSubmit, UserPromptExpansion and SessionStart, and this is none of
# them. Printing the record as text meant the gate could work perfectly and the
# skill still never heard about the commit.
#
# Messages accumulate and one envelope is emitted from an EXIT trap: the hook has
# a dozen exit points, two of them (`partial —` plus the record) say two things,
# and two JSON documents on stdout parse as neither. The skill's contract is
# unchanged — the text inside is the same, and only a line starting
# `obsidian-commit-capture: hash=` is a record.
#
# Deliberately NOT the shared cc_deliver_context: two of this hook's messages report
# that the parsing library is missing or unloadable, and a delivery path that lived in
# that library could not deliver them. The pre-hook, which has nothing to say until
# after the library loads, uses the shared one.
CC_OUT=""
say() { CC_OUT="${CC_OUT}obsidian-commit-capture: $1"$'\n'; }
cc_deliver() {
  local s="$CC_OUT"
  [ -n "$s" ] || return 0
  # Order matters: double the backslashes before introducing any of our own.
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  # A raw control byte is not legal in a JSON string, and a commit author picks
  # the subject. Anything left after the escapes above gets dropped rather than
  # allowed to make the envelope unparseable.
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037\177')"
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$s"
}
trap cc_deliver EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${SCRIPT_DIR}/lib/commit-capture-parse.sh"
if [ ! -f "$LIB" ]; then
  say "not captured — missing ${LIB} (reinstall the plugin)"
  exit 0
fi
# Guarded, like the pre-hook: a truncated lib (a partial plugin update) otherwise
# leaves every function undefined, and the gate below would swallow the resulting
# command-not-found as an ordinary non-commit call.
# shellcheck source=lib/commit-capture-parse.sh
if ! . "$LIB"; then
  say "not captured — ${LIB} failed to load (reinstall the plugin)"
  exit 0
fi

COMMAND_LINE="$(cc_json_value "$INPUT" '"command"')"
PAYLOAD_CWD="$(cc_json_value "$INPUT" '"cwd"')"

cc_invokes_commit "$COMMAND_LINE" || exit 0

# Which repo? The commit may have been made in a worktree via
# `cd <worktree> && git commit`, which is this project's documented workflow, so
# the hook's own cwd is the last candidate rather than the first.
REPO_DIR="$(cc_find_repo_dir "$PAYLOAD_CWD")" || exit 0
GIT() { git -C "$REPO_DIR" "$@"; }
REPO_ROOT=$(GIT rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
[ -n "$REPO_ROOT" ] || REPO_ROOT="$REPO_DIR"

# --- Did a commit actually land? ---

SNAP_FILE="$(cc_snapshot_file "$INPUT")"
HEAD_BEFORE=""
SNAP_ROOT=""
SNAP_INTENT=""
if [ -f "$SNAP_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in
      sha=*) HEAD_BEFORE="${line#sha=}" ;;
      root=*) SNAP_ROOT="${line#root=}" ;;
      intent=*) SNAP_INTENT="${line#intent=}" ;;
    esac
  done < "$SNAP_FILE"
  # Consumed: one snapshot answers for exactly one invocation, so a second
  # PostToolUse for the same call cannot re-capture the commit.
  rm -f "$SNAP_FILE" 2>/dev/null || true
fi

# Which of the three states is this snapshot in?
#
#   trusted   — it recorded THIS repo's HEAD, so HEAD_BEFORE is a real before-image.
#   blind     — it is about this repo (the command named it) but had no HEAD to read:
#               the repo did not exist yet at pre-time. `git worktree add ../wt && cd
#               ../wt && git commit` and `mkdir sub && cd sub && git init && git
#               commit` are both this shape, and both are common. There is no
#               before-image, so the fallback below has to decide.
#   foreign   — it is about some other repo. Its sha is unequal to this HEAD whether
#               or not anything was committed here, which is exactly the "unequal
#               tip, assume a commit" inference this gate removes. Discard it.
#
# `intent` is the repo the command *named*, recorded even when it did not resolve at
# pre-time. Without it a `cd <not-yet-a-repo>` snapshot fell back to the surrounding
# repo, the roots then disagreed, and the real commit was discarded as foreign.
SNAP_STATE="none"
if [ -n "$HEAD_BEFORE" ]; then
  if [ -n "$SNAP_ROOT" ] && [ "$SNAP_ROOT" = "$REPO_ROOT" ]; then
    SNAP_STATE="trusted"
  elif [ -n "$SNAP_INTENT" ]; then
    # The intent now resolves (the call created it). Compare repo roots, not path
    # strings: `../wt`, a symlinked /tmp, and the toplevel are the same repo.
    INTENT_DIR="$(cc_resolve_repo_dir "$SNAP_INTENT" "$PAYLOAD_CWD")" || INTENT_DIR=""
    if [ -n "$INTENT_DIR" ]; then
      INTENT_ROOT=$(git -C "$INTENT_DIR" rev-parse --show-toplevel 2>/dev/null) || INTENT_ROOT=""
      [ "$INTENT_ROOT" = "$REPO_ROOT" ] && SNAP_STATE="blind"
    fi
  fi
fi

case "$SNAP_STATE" in
  none)
    # Either the PreToolUse hook did not run for this call — a partial install, a
    # hand-wired config carrying only the PostToolUse half, a session predating the
    # pre-hook, or a state dir it could not write — or the snapshot it left belongs
    # to another repository. Both are reported: dropping a commit in silence is the
    # failure this whole mechanism exists to prevent.
    if [ -n "$HEAD_BEFORE" ]; then
      say "not captured — the PreToolUse snapshot for this call is about ${SNAP_ROOT:-another repository}, not ${REPO_ROOT}"
    else
      say "not captured — no PreToolUse HEAD snapshot for this call (register scripts/commit-capture-pre.sh as a PreToolUse Bash hook and restart the session; if it is registered, check that $(cc_state_dir) is writable)"
    fi
    exit 0
    ;;
esac

FULL_SHA=$(GIT rev-parse HEAD 2>/dev/null) || exit 0
case "$FULL_SHA" in
  *[!0-9a-f]*|'') exit 0 ;;
esac

# The gate: the tip moved during this call. A commit that was rejected, aborted,
# dry-run, short-circuited by `false &&`, or found nothing to commit leaves HEAD
# exactly where the snapshot found it.
if [ "$HEAD_BEFORE" = "$FULL_SHA" ]; then
  exit 0
fi

# HEAD moving is necessary but not sufficient — other operations move it too. Ask
# git what the move was rather than guessing from the clock:
#
#   - `git pull && git commit` where the commit failed leaves the *pulled* tip.
#     It is a fast-forward, so ancestry accepts it; the committer is not us, which
#     is what rejects it.
#   - `git checkout other && git commit` where the commit failed leaves another
#     branch's tip, which is not a descendant of where we were.
#   - `git reset --hard HEAD~1` leaves HEAD at the previous commit's parent.
#
# The wall clock used to stand in for all of this, and it was both too weak (a
# teammate's commit pulled within the window read as ours) and too strong (it
# discarded a commit the gate had positively observed whenever the Bash call kept
# working for two minutes afterwards — `git commit && npm test` lost the note, with
# no output on any stream). It is kept only for the blind case below, where there is
# no before-image to reason from.
RANGE_BASE=""
if [ "$SNAP_STATE" = "trusted" ] && [ "$HEAD_BEFORE" != "none" ]; then
  # An amend or a reset-then-commit makes the old tip a sibling, not an ancestor,
  # so its parent is what has to be reachable.
  if GIT merge-base --is-ancestor "$HEAD_BEFORE" "$FULL_SHA" >/dev/null 2>&1; then
    RANGE_BASE="$HEAD_BEFORE"
  elif GIT merge-base --is-ancestor "${HEAD_BEFORE}^" "$FULL_SHA" >/dev/null 2>&1; then
    # …but landing exactly ON that parent is an undo, not a commit.
    BEFORE_PARENT=$(GIT rev-parse "${HEAD_BEFORE}^" 2>/dev/null) || BEFORE_PARENT=""
    [ "$BEFORE_PARENT" != "$FULL_SHA" ] || exit 0
    RANGE_BASE="${HEAD_BEFORE}^"
  else
    exit 0
  fi
  # Whoever ran `git commit` is the committer, always — author can be overridden,
  # committer cannot. A commit that arrived over the wire carries someone else's.
  LOCAL_EMAIL=$(GIT config user.email 2>/dev/null) || LOCAL_EMAIL=""
  if [ -n "$LOCAL_EMAIL" ]; then
    HEAD_EMAIL=$(GIT log -1 --format=%ce 2>/dev/null) || HEAD_EMAIL=""
    [ -z "$HEAD_EMAIL" ] || [ "$HEAD_EMAIL" = "$LOCAL_EMAIL" ] || exit 0
  fi
fi

COMMIT_RECENT_WINDOW="${OBSIDIAN_COMMIT_RECENT_WINDOW:-120}"
HEAD_CT=$(GIT log -1 --format=%ct 2>/dev/null) || exit 0
case "$HEAD_CT" in
  *[!0-9]*|'') exit 0 ;;
esac
NOW_CT=$(date +%s)
AGE=$(( NOW_CT - HEAD_CT ))
# A HEAD dated in the future is not evidence a commit just happened — clock skew or
# a script-set GIT_COMMITTER_DATE would otherwise qualify until real time caught up.
# Allow a few seconds for jitter. The upper bound applies only to the blind case:
# with no before-image, freshness is the only thing separating this repo's brand-new
# first commit from history that was already there.
if [ "$AGE" -lt -5 ]; then
  exit 0
fi
if [ "$SNAP_STATE" = "blind" ] && [ "$AGE" -gt "$COMMIT_RECENT_WINDOW" ]; then
  exit 0
fi

# --- Extract git metadata ---

HASH=$(GIT rev-parse --short HEAD 2>/dev/null) || exit 0

# Which commits did this call make? Oldest first, so appending the records to a
# daily note reads in the order the work happened. Without a trusted before-image
# there is no range to walk and the tip is all we can claim.
SHAS="$FULL_SHA"
if [ -n "$RANGE_BASE" ]; then
  RANGE_LIST=$(GIT rev-list --reverse "${RANGE_BASE}..${FULL_SHA}" 2>/dev/null) || RANGE_LIST=""
  [ -z "$RANGE_LIST" ] || SHAS="$RANGE_LIST"
fi
# Which of those did this repo actually create? The committer check above catches a
# teammate's commit, but not your own commit pushed from another machine — same
# email, so `git pull && git commit` with a failing commit captured the pulled tip
# as though this call had made it (#72). Identity cannot separate those; provenance
# can. HEAD's reflog records how each ref update happened: a local commit leaves
# `commit: …` (or `commit (amend)`, `commit (initial)`), a real merge leaves
# `merge …: Merge made by …`, while anything that arrived over the wire leaves a
# Fast-forward entry — and the intermediate commits of a fast-forward appear in the
# reflog not at all, since only the final ref update is logged.
#
# Read the entry that created each sha rather than the top of the log: after
# `git commit && git checkout`, the newest entry is the checkout. That is why #68
# rejected `git reflog -1` and left this open.
# Every entry for the sha, not the newest: a sha keeps its `commit` entry while
# later operations add their own for the same value. `git commit && git checkout -b`
# logs the checkout against the same sha, so reading one entry — even the first
# matching one — answers "what happened last" instead of "was this created here".
cc_is_ours() {
  local sha="$1" entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "${entry#* }" in
      commit*) return 0 ;;
      merge*Fast-forward|pull*Fast-forward) ;;
      merge*) return 0 ;;
      *) ;;
    esac
  done <<EOF
$(printf '%s\n' "$REFLOG" | grep "^${sha} " || true)
EOF
  return 1
}
# No reflog at all (core.logAllRefUpdates off, the bare-repo default) means no
# evidence either way, and absent evidence is not evidence of a pull — capture.
REFLOG=$(GIT reflog show --format='%H %gs' 2>/dev/null) || REFLOG=""
if [ -n "$REFLOG" ]; then
  OURS=""
  for SHA_ONE in $SHAS; do
    if cc_is_ours "$SHA_ONE"; then
      OURS="${OURS}${SHA_ONE}"$'\n'
    fi
  done
  # Every commit in the range came from somewhere else, so this call made none.
  [ -n "$OURS" ] || exit 0
  SHAS="$OURS"
fi

SHA_COUNT=0
for SHA_ONE in $SHAS; do
  SHA_COUNT=$(( SHA_COUNT + 1 ))
done

# A record per commit is unbounded in principle — a scripted loop over paths can
# make dozens, and each one costs the skill a note. Cap it, and name what the cap
# dropped: a truncated capture is indistinguishable from a complete one otherwise.
MAX_RECORDS="${OBSIDIAN_COMMIT_MAX_RECORDS:-20}"
case "$MAX_RECORDS" in
  ''|*[!0-9]*|0) MAX_RECORDS=20 ;;
esac
if [ "$SHA_COUNT" -gt "$MAX_RECORDS" ]; then
  KEPT=""
  SKIPPED=""
  N=0
  for SHA_ONE in $SHAS; do
    N=$(( N + 1 ))
    if [ "$N" -le "$MAX_RECORDS" ]; then
      KEPT="${KEPT}${SHA_ONE}"$'\n'
    else
      SKIPPED="${SKIPPED}$(GIT rev-parse --short "$SHA_ONE" 2>/dev/null) "
    fi
  done
  SHAS="$KEPT"
  say "partial — this call made ${SHA_COUNT} commits; the oldest ${MAX_RECORDS} are captured, skipped: ${SKIPPED% }"
fi

# The record below is ` | `-delimited and the skill parses it by field name, turning
# org_repo into a path under the vault and vault_path into a --vault argument. Any
# field a commit author controls can therefore inject its own `org_repo=` /
# `vault_path=` ahead of the real one, and a reader taking the first match resolves
# the attacker's. `msg` was moved last and stripped for this reason — but a *path* is
# author-controlled too (`|` is legal in a filename and in a refname), and `files=`
# and `branch=` both precede the fields they could spoof. Strip all three.
scrub_field() {
  local s="$1"
  s="${s//|/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

BRANCH=$(GIT rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH="unknown"
BRANCH="$(scrub_field "$BRANCH")"

# The subject and the file list are per commit; everything else below (branch,
# org_repo, vault_path, the clock) is a property of the call and is shared.
# One invocation that answers for all three shapes (#65). `HEAD~1..HEAD` failed
# outright on a root commit — silently, so `files=` was simply empty — and reported
# only the first-parent diff on a merge. `--root` covers the root commit;
# `-m --first-parent` makes a merge report the paths it brought in rather than
# nothing, which is what a note about a merge is for. Note that `git show
# --name-only`, the fix the issue proposed, prints nothing at all for a merge.
cc_files_for() {
  local raw=""
  raw=$(GIT diff-tree --no-commit-id --name-only -r --root -m --first-parent "$1" 2>/dev/null) || raw=""
  printf '%s' "$raw" | tr '\n' ',' | sed 's/,$//'
}

REMOTE=$(GIT remote get-url origin 2>/dev/null) || REMOTE="local"
# In a worktree the toplevel is the worktree directory, so its basename is
# `obsidian-i82` or `wp-content-pr7100-slug` rather than the repository. That name
# reaches a note's `tags:` and its H1, and PR work happens in worktrees by
# convention — so most PR commits tagged the daily note with a directory that no
# longer exists a week later. The linked worktrees share one common git dir; its
# parent is the main worktree, which is the repository as far as the filesystem
# can say. (The remote says it better still — see below, once it is parsed.)
GIT_COMMON=$(GIT rev-parse --git-common-dir 2>/dev/null) || GIT_COMMON=""
case "$GIT_COMMON" in
  '') MAIN_ROOT="$REPO_ROOT" ;;
  /*) MAIN_ROOT="$GIT_COMMON" ;;
  # Relative, and relative to the directory git ran in — not to the toplevel.
  *)  MAIN_ROOT="${REPO_DIR}/${GIT_COMMON}" ;;
esac
MAIN_ROOT="${MAIN_ROOT%/}"
MAIN_ROOT="${MAIN_ROOT%/.git}"
REPO_NAME=${MAIN_ROOT##*/}
REPO_NAME=${REPO_NAME%.git}
: "${REPO_NAME:=unknown}"
TODAY=$(date '+%Y-%m-%d')
NOW=$(date '+%H:%M')

# --- Derive org/repo from remote URL ---

# The derivation (host-agnostic, userinfo stripped, subgroups folded, traversal
# rejected) lives in cc_org_repo so the Cursor and Codex integrations can call
# the same implementation instead of restating it. See the function for the
# incident history behind each clause.
ORG_REPO="$(cc_org_repo "$REMOTE" "$REPO_NAME")"
# Now that the remote has been parsed, it — not any directory — is what names the
# repository: a clone is free to sit in a directory called anything, and a worktree
# always does. The `local/` form means no remote resolved, and there the directory
# above is already the best available answer.
case "$ORG_REPO" in
  local/*) ;;
  */*) REPO_NAME="${ORG_REPO##*/}" ;;
esac

# --- Extract ticket number from branch ---

TICKET=""
REMAINING="$BRANCH"
while [ -n "$REMAINING" ]; do
  case "$REMAINING" in
    */[0-9]*)
      AFTER_SLASH="${REMAINING#*/}"
      DIGITS=""
      REST="$AFTER_SLASH"
      while [ -n "$REST" ]; do
        CHAR="${REST%"${REST#?}"}"
        case "$CHAR" in
          [0-9]) DIGITS="${DIGITS}${CHAR}" ;;
          *) break ;;
        esac
        REST="${REST#?}"
      done
      if [ ${#DIGITS} -ge 2 ] && [ ${#DIGITS} -le 5 ]; then
        TICKET="$DIGITS"
        break
      fi
      REMAINING="$AFTER_SLASH"
      ;;
    *)
      break
      ;;
  esac
done

# --- Resolve vault_path from obsidian.local.md ---
# Inline this in the hook output so the skill doesn't have to Read the config
# file on every commit. The config rarely changes; if it does, the next commit
# picks up the new value.

VAULT_PATH=""
CONFIG_FILE=""
# Sourced unguarded, a partial install produced two shell errors, an empty
# vault_path — which the skill skips silently, by contract — and (before the
# HEAD-snapshot gate) a marker on disk that made the miss unretryable.
if [ -f "${SCRIPT_DIR}/lib/resolve-config.sh" ]; then
  . "${SCRIPT_DIR}/lib/resolve-config.sh"
  CONFIG_FILE="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}")" || CONFIG_FILE=""
fi
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in
      vault_path:*)
        VAULT_PATH="${line#vault_path:}"
        # Strip trailing CR from CRLF-edited configs before any other parsing.
        VAULT_PATH="${VAULT_PATH%$'\r'}"
        # Strip an inline "# comment" tail before quote/whitespace handling.
        case "$VAULT_PATH" in
          *' #'*) VAULT_PATH="${VAULT_PATH%% #*}" ;;
          *$'\t#'*) VAULT_PATH="${VAULT_PATH%%	#*}" ;;
        esac
        VAULT_PATH="${VAULT_PATH# }"
        VAULT_PATH="${VAULT_PATH#	}"
        VAULT_PATH="${VAULT_PATH% }"
        VAULT_PATH="${VAULT_PATH%	}"
        VAULT_PATH="${VAULT_PATH#\"}"
        VAULT_PATH="${VAULT_PATH%\"}"
        VAULT_PATH="${VAULT_PATH#\'}"
        VAULT_PATH="${VAULT_PATH%\'}"
        case "$VAULT_PATH" in
          '~/'*) VAULT_PATH="${HOME}/${VAULT_PATH#\~/}" ;;
          '~') VAULT_PATH="${HOME}" ;;
        esac
        break
        ;;
    esac
  done < "$CONFIG_FILE"
fi

# --- Output metadata inline for the obsidian:commit-capture skill ---

# With no vault_path the skill has nothing to write to and skips silently, so
# emitting the record would burn the capture. Say so on stderr instead.
if [ -z "$VAULT_PATH" ]; then
  say "not captured — ${HASH}: vault_path unresolved (run /obsidian:setup)"
  exit 0
fi

# msg is the only free-form field, so it goes last. With it in the middle, a
# subject reading `chore: tidy | org_repo=../../tmp/pwned | vault_path=/tmp/evil`
# put an attacker-chosen org_repo and vault_path *ahead* of the real ones, and
# whoever parses the first match resolves a path outside the vault. Last means
# every parseable field precedes anything a commit author can influence.
#
# One record per commit this call made, oldest first. The skill reads each line
# independently, so several records from one invocation need no new contract.
for SHA_ONE in $SHAS; do
  ONE_HASH=$(GIT rev-parse --short "$SHA_ONE" 2>/dev/null) || continue
  ONE_MSG=$(GIT log -1 --pretty=format:'%s' "$SHA_ONE" 2>/dev/null) || ONE_MSG=""
  say "$(printf 'hash=%s | branch=%s | files=%s | org_repo=%s | repo_name=%s | ticket=%s | date=%s | time=%s | vault_path=%s | msg=%s' \
    "$ONE_HASH" "$BRANCH" "$(scrub_field "$(cc_files_for "$SHA_ONE")")" "$ORG_REPO" "$REPO_NAME" \
    "$TICKET" "$TODAY" "$NOW" "$VAULT_PATH" "$(scrub_field "$ONE_MSG")")"
done
