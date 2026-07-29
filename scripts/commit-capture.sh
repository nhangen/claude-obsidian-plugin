#!/usr/bin/env bash
# commit-capture.sh
# PostToolUse command hook. Detects git commits from Bash tool output,
# extracts metadata, and outputs it inline. Non-commit Bash calls exit silently.

set -uo pipefail

INPUT=$(cat)

# --- Quick exit for non-commit commands ---

case "$INPUT" in
  *'"command"'*'git commit'*) ;;
  *) exit 0 ;;
esac

# `git commit` must be an actual command word, not a substring. Matching the
# substring captured `grep -rn "git commit" docs/`, `echo "run git commit"`, and
# `git log --grep="git commit"` — each of which fires the hook and, with a recent
# HEAD, re-captures whatever commit happened to be at the tip.
# Split the command on shell separators and require some segment to *invoke*
# git with the `commit` subcommand.
COMMAND_LINE="${INPUT#*'"command"'}"
COMMAND_LINE="${COMMAND_LINE#*'"'}"
COMMAND_LINE="${COMMAND_LINE%%'"'*}"
INVOKES_COMMIT=0
SEGMENTS="$COMMAND_LINE"
SEGMENTS="${SEGMENTS//&&/$'\n'}"
SEGMENTS="${SEGMENTS//||/$'\n'}"
SEGMENTS="${SEGMENTS//;/$'\n'}"
SEGMENTS="${SEGMENTS//|/$'\n'}"
while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"          # ltrim
  case "$seg" in
    git' '*) ;;
    *) continue ;;
  esac
  seg="${seg#git }"
  # skip git global flags that take a value, then any remaining flags
  while :; do
    case "$seg" in
      -C' '*|--git-dir*' '*|--work-tree*' '*)
        seg="${seg#* }"; seg="${seg#* }" ;;
      -*' '*) seg="${seg#* }" ;;
      *) break ;;
    esac
  done
  case "$seg" in
    commit|commit' '*) INVOKES_COMMIT=1; break ;;
  esac
done <<EOF
$SEGMENTS
EOF
[ "$INVOKES_COMMIT" -eq 1 ] || exit 0

case "$INPUT" in
  *'--dry-run'*)
    exit 0
    ;;
esac

# Failure text. The old list matched three phrases and `"error:` (which only
# fires when stderr *starts* with it), so a rejected pre-commit hook and
# `fatal: cannot do a partial commit during a merge` both read as success.
case "$INPUT" in
  *'nothing to commit'*|*'nothing added'*|*'no changes added'*|*'Aborting'*  |*'error:'*|*'fatal:'*|*'exited with code'*|*'hook failed'*|*'Untracked files'*)
    exit 0
    ;;
esac

# Which repo? The commit may have been made in a worktree via
# `cd <worktree> && git commit`, which is this project's documented workflow.
# Running git in the hook's own cwd read the wrong HEAD — dropping the capture
# when the session repo was idle, or capturing the wrong commit when it wasn't.
REPO_DIR=""
case "$INPUT" in
  *'"cwd"'*)
    REPO_DIR="${INPUT#*'"cwd"'}"
    REPO_DIR="${REPO_DIR#*'"'}"
    REPO_DIR="${REPO_DIR%%'"'*}"
    ;;
esac
# An explicit `cd <path> &&` in the command wins: it is where git actually ran.
CMD="${INPUT#*'"command"'}"
CMD="${CMD#*'"'}"
CMD="${CMD%%'"'*}"
case "$CMD" in
  'cd '*)
    CD_PATH="${CMD#cd }"
    case "$CD_PATH" in
      '"'*) CD_PATH="${CD_PATH#\"}"; CD_PATH="${CD_PATH%%\"*}" ;;
      "'"*) CD_PATH="${CD_PATH#\'}"; CD_PATH="${CD_PATH%%\'*}" ;;
      *) CD_PATH="${CD_PATH%% *}" ;;
    esac
    [ -d "$CD_PATH" ] && REPO_DIR="$CD_PATH"
    ;;
esac
[ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ] || REPO_DIR="$PWD"
GIT() { git -C "$REPO_DIR" "$@"; }

# Confirm a commit actually landed, and that it is one we have not already
# captured. The old gate required the "[branch hash]" summary line, which
# `git commit -q` does not print, so every quiet commit was silently skipped.
# Asking git instead needs two parts: the sha must be new (otherwise any later
# Bash call that merely mentions `git commit` re-captures the same commit, and a
# failed commit re-captures its predecessor), and it must be recent (otherwise a
# first-ever mention captures unrelated history).
FULL_SHA=$(GIT rev-parse HEAD 2>/dev/null) || exit 0
case "$FULL_SHA" in
  *[!0-9a-f]*|'') exit 0 ;;
esac

COMMIT_RECENT_WINDOW="${OBSIDIAN_COMMIT_RECENT_WINDOW:-120}"
HEAD_CT=$(GIT log -1 --format=%ct 2>/dev/null) || exit 0
case "$HEAD_CT" in
  *[!0-9]*|'') exit 0 ;;
esac
NOW_CT=$(date +%s)
AGE=$(( NOW_CT - HEAD_CT ))
# A HEAD dated in the future is not evidence a commit just happened — clock skew
# or a script-set GIT_COMMITTER_DATE would otherwise make every mention qualify
# until real time caught up. Allow a few seconds for jitter.
if [ "$AGE" -lt -5 ] || [ "$AGE" -gt "$COMMIT_RECENT_WINDOW" ]; then
  exit 0
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-obsidian"
SHA_SLUG=$(printf '%s' "$REPO_DIR" | tr -c 'A-Za-z0-9._-' '_')
SHA_FILE="${STATE_DIR}/last-capture-${SHA_SLUG}"
if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE" 2>/dev/null)" = "$FULL_SHA" ]; then
  exit 0
fi

# --- Extract git metadata ---

HASH=$(GIT rev-parse --short HEAD 2>/dev/null) || exit 0
MSG=$(GIT log -1 --pretty=format:'%s' 2>/dev/null) || MSG=""
BRANCH=$(GIT rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH="unknown"
FILES_RAW=$(GIT diff --name-only HEAD~1..HEAD 2>/dev/null) || FILES_RAW=""
FILES=$(printf '%s' "$FILES_RAW" | tr '\n' ',' | sed 's/,$//')
REMOTE=$(GIT remote get-url origin 2>/dev/null) || REMOTE="local"
REPO_ROOT=$(GIT rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/resolve-config.sh"
CONFIG_FILE="$(resolve_obsidian_config "${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}")" || CONFIG_FILE=""
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

mkdir -p "$STATE_DIR" 2>/dev/null || true
printf '%s\n' "$FULL_SHA" > "$SHA_FILE" 2>/dev/null || true

printf 'obsidian-commit-capture: hash=%s | msg=%s | branch=%s | files=%s | org_repo=%s | repo_name=%s | ticket=%s | date=%s | time=%s | vault_path=%s\n' \
  "$HASH" "$MSG" "$BRANCH" "$FILES" "$ORG_REPO" "$REPO_NAME" "$TICKET" "$TODAY" "$NOW" "$VAULT_PATH"
