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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${SCRIPT_DIR}/lib/commit-capture-parse.sh"
if [ ! -f "$LIB" ]; then
  printf 'obsidian-commit-capture: not captured — missing %s (reinstall the plugin)\n' "$LIB" >&2
  exit 0
fi
# shellcheck source=lib/commit-capture-parse.sh
. "$LIB"

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
if [ -f "$SNAP_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in
      sha=*) HEAD_BEFORE="${line#sha=}" ;;
      root=*) SNAP_ROOT="${line#root=}" ;;
    esac
  done < "$SNAP_FILE"
  # Consumed: one snapshot answers for exactly one invocation, so a second
  # PostToolUse for the same call cannot re-capture the commit.
  rm -f "$SNAP_FILE" 2>/dev/null || true
fi

# A snapshot taken against a different repository says nothing about this one.
# Without a tool_use_id in the payload the key is only session-scoped, so two
# concurrent commits in one session can cross — hence the recorded root. There is
# no safe way to reuse the other repo's sha: it is unequal to this HEAD whether or
# not anything was committed here, which is exactly the "recent tip, assume a
# commit" inference this gate exists to remove. Discard it and say so.
if [ -n "$SNAP_ROOT" ] && [ "$SNAP_ROOT" != "$REPO_ROOT" ]; then
  HEAD_BEFORE=""
fi

# No usable snapshot means the PreToolUse hook did not run for this call — a
# partial install, a hand-wired hook config carrying only the PostToolUse half, or
# a session that predates the pre-hook. Say so instead of dropping the capture
# silently; the message names the fix.
if [ -z "$HEAD_BEFORE" ]; then
  printf 'obsidian-commit-capture: not captured — no PreToolUse HEAD snapshot for this call (register scripts/commit-capture-pre.sh as a PreToolUse Bash hook, then restart the session)\n' >&2
  exit 0
fi

FULL_SHA=$(GIT rev-parse HEAD 2>/dev/null) || exit 0
case "$FULL_SHA" in
  *[!0-9a-f]*|'') exit 0 ;;
esac

# The whole gate: the tip moved during this call. A commit that was rejected,
# aborted, dry-run, short-circuited by `false &&`, or found nothing to commit
# leaves HEAD exactly where the snapshot found it.
if [ "$HEAD_BEFORE" = "$FULL_SHA" ]; then
  exit 0
fi

# HEAD can also move without a commit of ours landing: `git pull && git commit`
# where the commit failed leaves the pulled tip, and so does a `git checkout` in
# front of a failed commit. Requiring a freshly-dated tip rejects both, because
# what arrived over the wire or was already on another branch was committed
# earlier. This is a corroborating check, not the gate — on its own it was what
# let a failed commit inherit its predecessor.
COMMIT_RECENT_WINDOW="${OBSIDIAN_COMMIT_RECENT_WINDOW:-120}"
HEAD_CT=$(GIT log -1 --format=%ct 2>/dev/null) || exit 0
case "$HEAD_CT" in
  *[!0-9]*|'') exit 0 ;;
esac
NOW_CT=$(date +%s)
AGE=$(( NOW_CT - HEAD_CT ))
# A HEAD dated in the future is not evidence a commit just happened — clock skew
# or a script-set GIT_COMMITTER_DATE would otherwise qualify until real time
# caught up. Allow a few seconds for jitter.
if [ "$AGE" -lt -5 ] || [ "$AGE" -gt "$COMMIT_RECENT_WINDOW" ]; then
  exit 0
fi

# --- Extract git metadata ---

HASH=$(GIT rev-parse --short HEAD 2>/dev/null) || exit 0
MSG=$(GIT log -1 --pretty=format:'%s' 2>/dev/null) || MSG=""
# The record below is ` | `-delimited and the skill parses it by field name,
# turning org_repo into a path under the vault and vault_path into a --vault
# argument. A subject containing ` | org_repo=…` injected its own fields ahead of
# the real ones, so the delimiter cannot survive in free-form text.
MSG="${MSG//|/ }"
MSG="${MSG//$'\r'/ }"
MSG="${MSG//$'\n'/ }"
BRANCH=$(GIT rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH="unknown"
FILES_RAW=$(GIT diff --name-only HEAD~1..HEAD 2>/dev/null) || FILES_RAW=""
FILES=$(printf '%s' "$FILES_RAW" | tr '\n' ',' | sed 's/,$//')
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
  printf 'obsidian-commit-capture: %s not captured — vault_path unresolved (run /obsidian:setup)\n' "$HASH" >&2
  exit 0
fi

# msg is the only free-form field, so it goes last. With it in the middle, a
# subject reading `chore: tidy | org_repo=../../tmp/pwned | vault_path=/tmp/evil`
# put an attacker-chosen org_repo and vault_path *ahead* of the real ones, and
# whoever parses the first match resolves a path outside the vault. Last means
# every parseable field precedes anything a commit author can influence.
printf 'obsidian-commit-capture: hash=%s | branch=%s | files=%s | org_repo=%s | repo_name=%s | ticket=%s | date=%s | time=%s | vault_path=%s | msg=%s\n' \
  "$HASH" "$BRANCH" "$FILES" "$ORG_REPO" "$REPO_NAME" "$TICKET" "$TODAY" "$NOW" "$VAULT_PATH" "$MSG"
