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

# Diagnostics go to stdout, not stderr. A hook that exits 0 has its stdout read
# (that is how the record below reaches the skill at all); exit-0 stderr has no
# documented surface, so a "not captured" line written there is indistinguishable
# from dropping the capture in silence. The skill knows that only a line starting
# `obsidian-commit-capture: hash=` is a record.
say() { printf 'obsidian-commit-capture: %s\n' "$1"; }

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

SNAP_FILE="$(cc_state_dir)/pre-commit-head/$(cc_snapshot_key "$INPUT")"
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
      say "not captured — no PreToolUse HEAD snapshot for this call (register scripts/commit-capture-pre.sh as a PreToolUse Bash hook and restart the session; if it is registered, check that ${XDG_STATE_HOME:-$HOME/.local/state}/claude-obsidian is writable)"
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
if [ "$SNAP_STATE" = "trusted" ] && [ "$HEAD_BEFORE" != "none" ]; then
  # An amend or a reset-then-commit makes the old tip a sibling, not an ancestor,
  # so its parent is what has to be reachable.
  if GIT merge-base --is-ancestor "$HEAD_BEFORE" "$FULL_SHA" >/dev/null 2>&1; then
    :
  elif GIT merge-base --is-ancestor "${HEAD_BEFORE}^" "$FULL_SHA" >/dev/null 2>&1; then
    # …but landing exactly ON that parent is an undo, not a commit.
    BEFORE_PARENT=$(GIT rev-parse "${HEAD_BEFORE}^" 2>/dev/null) || BEFORE_PARENT=""
    [ "$BEFORE_PARENT" != "$FULL_SHA" ] || exit 0
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

MSG=$(GIT log -1 --pretty=format:'%s' 2>/dev/null) || MSG=""
MSG="$(scrub_field "$MSG")"
BRANCH=$(GIT rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH="unknown"
BRANCH="$(scrub_field "$BRANCH")"
FILES_RAW=$(GIT diff --name-only HEAD~1..HEAD 2>/dev/null) || FILES_RAW=""
FILES=$(printf '%s' "$FILES_RAW" | tr '\n' ',' | sed 's/,$//')
FILES="$(scrub_field "$FILES")"

# One snapshot answers for one invocation, so a call that made several commits emits
# one record — for the tip. Name the others: a silent partial capture reads exactly
# like a complete one.
if [ "$SNAP_STATE" = "trusted" ] && [ "$HEAD_BEFORE" != "none" ]; then
  EXTRA=$(GIT rev-list --count "${HEAD_BEFORE}..${FULL_SHA}" 2>/dev/null) || EXTRA=""
  case "$EXTRA" in
    ''|*[!0-9]*) ;;
    *) if [ "$EXTRA" -gt 1 ]; then
         say "partial — this call made ${EXTRA} commits; only ${HASH} is captured, skipped: $(GIT log --format=%h "${HEAD_BEFORE}..${FULL_SHA}^" 2>/dev/null | tr '\n' ' ')"
       fi ;;
  esac
fi
REMOTE=$(GIT remote get-url origin 2>/dev/null) || REMOTE="local"
REPO_NAME=${REPO_ROOT##*/}
: "${REPO_NAME:=unknown}"
TODAY=$(date '+%Y-%m-%d')
NOW=$(date '+%H:%M')

# --- Derive org/repo from remote URL ---

# Host-agnostic, and userinfo is stripped before splitting. The old version
# matched SSH and github.com only, so an HTTPS GitLab remote fell through to
# local/<repo> — one repo recorded under three org_repo values, hence three
# capture folders. Stripping userinfo is not cosmetic: a remote carrying a token
# (https://oauth2:TOKEN@host:8443/org/repo.git) matched the SSH arm and the token
# survived into org_repo, which is printed and written into a note's `repo:`
# frontmatter, then synced. See no-secrets-in-logs.
ORG_REPO=""
REMOTE_PATH="$REMOTE"
case "$REMOTE_PATH" in
  *://*) REMOTE_PATH="${REMOTE_PATH#*://}" ;;
esac
# Drop userinfo (anything before an @ that precedes the first /).
case "$REMOTE_PATH" in
  *@*)
    HOSTPART="${REMOTE_PATH%%/*}"
    case "$HOSTPART" in
      *@*) REMOTE_PATH="${HOSTPART##*@}${REMOTE_PATH#"$HOSTPART"}" ;;
    esac
    ;;
esac
# A colon is either an scp-style host:path separator or a port. Decide by what
# follows it: all digits means port (drop it), anything else means path.
HOSTPART="${REMOTE_PATH%%/*}"
REST=""
case "$REMOTE_PATH" in
  */*) REST="${REMOTE_PATH#*/}" ;;
esac
case "$HOSTPART" in
  *:*)
    AFTER_COLON="${HOSTPART##*:}"
    case "$AFTER_COLON" in
      ''|*[!0-9]*) ORG_REPO="${AFTER_COLON}${REST:+/$REST}" ;;
      *)           ORG_REPO="$REST" ;;
    esac
    ;;
  *) ORG_REPO="$REST" ;;
esac
ORG_REPO="${ORG_REPO#/}"
while :; do
  case "$ORG_REPO" in
    */) ORG_REPO="${ORG_REPO%/}" ;;
    *)  break ;;
  esac
done
ORG_REPO="${ORG_REPO%.git}"
case "$ORG_REPO" in
  ''|*/|*/*) : ;;
  *) ORG_REPO="" ;;                       # single segment is not org/repo
esac
case "$REMOTE" in
  ''|local) ORG_REPO="" ;;
  /*|./*|../*) ORG_REPO="" ;;             # bare local path
  file://*) ORG_REPO="" ;;
esac
# org_repo becomes a directory under the vault, so it must not escape it. A
# remote of https://host/../../../../tmp/pwned.git derived cleanly into
# `../../../../tmp/pwned`, with nothing downstream to catch it.
case "$ORG_REPO" in
  /*|*..*) ORG_REPO="" ;;
esac
case "$ORG_REPO" in
  ''|*/) ORG_REPO="local/$REPO_NAME" ;;
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
printf 'obsidian-commit-capture: hash=%s | branch=%s | files=%s | org_repo=%s | repo_name=%s | ticket=%s | date=%s | time=%s | vault_path=%s | msg=%s\n' \
  "$HASH" "$BRANCH" "$FILES" "$ORG_REPO" "$REPO_NAME" "$TICKET" "$TODAY" "$NOW" "$VAULT_PATH" "$MSG"
