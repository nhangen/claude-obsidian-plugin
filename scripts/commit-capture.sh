#!/usr/bin/env bash
# commit-capture.sh
# PostToolUse command hook. Detects git commits from Bash tool output,
# extracts metadata, and outputs it inline. Non-commit Bash calls exit silently.

set -uo pipefail

INPUT=$(cat)

# --- Quick exit for non-commit commands ---

case "$INPUT" in
  *'"command"'*commit*) ;;
  *) exit 0 ;;
esac

# The payload is JSON: a quote inside the command arrives as \" and a newline as
# the two characters \n. Truncating a value at the first `"` therefore cut the
# command short at its first quoted argument, silently dropping
# `cd "<worktree>" && git commit` — this project's own documented workflow — and
# `git add "a b.txt" && git commit`. Decode the string instead of slicing it.
json_value() {
  local s="$1" key="$2" out="" ch
  s="${s#*"$key"}"
  [ "$s" != "$1" ] || { printf '%s' ''; return 0; }
  s="${s#*\"}"
  while [ -n "$s" ]; do
    ch="${s%"${s#?}"}"
    s="${s#?}"
    case "$ch" in
      '"') break ;;
      '\')
        ch="${s%"${s#?}"}"
        s="${s#?}"
        case "$ch" in
          n) out="${out}"$'\n' ;;
          t) out="${out}"$'\t' ;;
          r) out="${out}"$'\r' ;;
          b|f) out="${out} " ;;
          u) s="${s#????}"; out="${out}?" ;;
          *) out="${out}${ch}" ;;
        esac
        ;;
      *) out="${out}${ch}" ;;
    esac
  done
  printf '%s' "$out"
}

COMMAND_LINE="$(json_value "$INPUT" '"command"')"
PAYLOAD_CWD="$(json_value "$INPUT" '"cwd"')"
# Failure text must be judged on what the tool reported, never on the command or
# the commit message. Matching the whole payload discarded a successful commit
# whose subject contained `fatal:`, `error:`, or `--dry-run`.
RESPONSE=""
case "$INPUT" in
  *'"tool_response"'*) RESPONSE="${INPUT#*'"tool_response"'}" ;;
esac

# Pull the first shell token off a string, honouring "…" and '…' so a path with
# spaces survives. Sets TOKEN and REST.
TOKEN=""
REST=""
take_token() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  case "$s" in
    '"'*) s="${s#\"}"; TOKEN="${s%%\"*}"; REST="${s#"$TOKEN"}"; REST="${REST#\"}" ;;
    "'"*) s="${s#\'}"; TOKEN="${s%%\'*}"; REST="${s#"$TOKEN"}"; REST="${REST#\'}" ;;
    *)    TOKEN="${s%%[[:space:]]*}"; REST="${s#"$TOKEN"}" ;;
  esac
  REST="${REST#"${REST%%[![:space:]]*}"}"
}

# `git commit` must be an actual command word, not a substring. Matching the
# substring captured `grep -rn "git commit" docs/`, `echo "run git commit"`, and
# `git log --grep="git commit"` — each of which fires the hook and, with a recent
# HEAD, re-captures whatever commit happened to be at the tip.
# Split the command on shell separators and require some segment to *invoke* git
# with the `commit` subcommand. A newline is a separator too: it arrives decoded
# by now, and `git add -A` on one line with `git commit` on the next is the most
# common shape there is.
INVOKES_COMMIT=0
GIT_C_DIR=""
CD_TARGET=""
SEGMENTS="$COMMAND_LINE"
SEGMENTS="${SEGMENTS//&&/$'\n'}"
SEGMENTS="${SEGMENTS//||/$'\n'}"
SEGMENTS="${SEGMENTS//;/$'\n'}"
SEGMENTS="${SEGMENTS//|/$'\n'}"
while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"          # ltrim
  # Shell keywords and grouping tokens sit in front of the real command word, so
  # `if true; then git commit; fi` and `for f in a; do git commit; done` used to
  # miss entirely.
  while :; do
    case "$seg" in
      'then '*|'do '*|'else '*|'elif '*|'time '*|'exec '*|'! '*|'{ '*)
        seg="${seg#* }" ;;
      '('*|'{'*) seg="${seg#?}" ;;
      *) break ;;
    esac
    seg="${seg#"${seg%%[![:space:]]*}"}"
  done
  # Leading VAR=value assignments (GIT_AUTHOR_DATE=… git commit …).
  while :; do
    case "$seg" in
      [A-Za-z_]*=*)
        assign="${seg%%=*}"
        case "$assign" in
          *[!A-Za-z0-9_]*) break ;;
        esac
        case "$seg" in
          *' '*) seg="${seg#* }"; seg="${seg#"${seg%%[![:space:]]*}"}" ;;
          *) break ;;
        esac
        ;;
      *) break ;;
    esac
  done
  take_token "$seg"
  word="$TOKEN"
  args="$REST"
  # Match the basename so /usr/bin/git counts, and remember a `cd` target: it is
  # where git actually ran.
  case "${word##*/}" in
    cd)
      while :; do
        case "$args" in
          -*) take_token "$args"; args="$REST" ;;
          *) break ;;
        esac
      done
      take_token "$args"
      [ -n "$TOKEN" ] && [ -z "$CD_TARGET" ] && CD_TARGET="$TOKEN"
      continue
      ;;
    git) ;;
    *) continue ;;
  esac
  [ -n "$args" ] || continue
  # Skip git's global flags. `-C <dir>` is recorded, not just skipped: the gate
  # used to parse it while resolution ignored it, so the two layers disagreed
  # about which repository the commit landed in.
  while :; do
    case "$args" in
      -C' '*|-c' '*|--git-dir' '*|--work-tree' '*|--namespace' '*|--exec-path' '*)
        flag="${args%%[[:space:]]*}"
        args="${args#"$flag"}"
        args="${args#"${args%%[![:space:]]*}"}"
        take_token "$args"
        [ "$flag" = "-C" ] && [ -z "$GIT_C_DIR" ] && GIT_C_DIR="$TOKEN"
        args="$REST"
        ;;
      -*) take_token "$args"; args="$REST" ;;
      *) break ;;
    esac
    [ -n "$args" ] || break
  done
  case "$args" in
    commit|commit' '*|commit$'\t'*) INVOKES_COMMIT=1; break ;;
  esac
done <<EOF
$SEGMENTS
EOF
[ "$INVOKES_COMMIT" -eq 1 ] || exit 0

case "$COMMAND_LINE" in
  *--dry-run*)
    exit 0
    ;;
esac

# Failure text. The old list matched three phrases and `"error:` (which only
# fires when stderr *starts* with it), so a rejected pre-commit hook and
# `fatal: cannot do a partial commit during a merge` both read as success.
case "$RESPONSE" in
  *'nothing to commit'*|*'nothing added'*|*'no changes added'*|*'Aborting'*  |*'error:'*|*'fatal:'*|*'exited with code'*|*'hook failed'*|*'Untracked files'*)
    exit 0
    ;;
esac

# Which repo? The commit may have been made in a worktree via
# `cd <worktree> && git commit`, which is this project's documented workflow.
# Running git in the hook's own cwd read the wrong HEAD — dropping the capture
# when the session repo was idle, or capturing the wrong commit when it wasn't.
# A relative `cd` has to be resolved against the payload's cwd, not the hook's:
# with a same-named directory beside the hook it captured a different
# repository's commit outright, and filed the note under that repo's name.
resolve_repo_dir() {
  local d="$1"
  [ -n "$d" ] || return 1
  case "$d" in
    '~') d="$HOME" ;;
    '~/'*) d="$HOME/${d#\~/}" ;;
  esac
  case "$d" in
    /*) ;;
    *)
      [ -n "$PAYLOAD_CWD" ] || return 1
      d="$PAYLOAD_CWD/$d"
      ;;
  esac
  [ -d "$d" ] || return 1
  git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  printf '%s' "$d"
}

REPO_DIR=""
for cand in "$GIT_C_DIR" "$CD_TARGET" "$PAYLOAD_CWD" "$PWD"; do
  [ -n "$cand" ] || continue
  REPO_DIR="$(resolve_repo_dir "$cand")" && break
  REPO_DIR=""
done
[ -n "$REPO_DIR" ] || exit 0
GIT() { git -C "$REPO_DIR" "$@"; }

# Resolved once, above the dedup gate, because the gate has to key on the
# repository rather than on whatever cwd string this invocation happened to
# carry — `$R`, `$R/sub` and `$R/` are one repo and produced three captures.
REPO_ROOT=$(GIT rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
[ -n "$REPO_ROOT" ] || REPO_ROOT="$REPO_DIR"

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
# Keyed on a bounded digest of the repo root. Slugging the raw path both split
# one repo across several keys and, in a deep worktree, exceeded NAME_MAX — the
# open failed, the error went to the hook's stderr, and dedup stayed off.
ROOT_KEY=$(printf '%s' "$REPO_ROOT" | cksum 2>/dev/null | tr -cd '0-9') || ROOT_KEY=""
[ -n "$ROOT_KEY" ] || ROOT_KEY="unkeyed"
SHA_FILE="${STATE_DIR}/last-capture-${ROOT_KEY}"
if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE" 2>/dev/null)" = "$FULL_SHA" ]; then
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE=""
# Sourced unguarded, a partial install produced two shell errors, an empty
# vault_path — which the skill skips silently, by contract — and a captured
# marker already on disk, making the miss permanently unretryable.
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
# emitting the record would burn the capture. Say so on stderr and leave no
# marker, which keeps the next invocation able to retry.
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

# Marker last, and brace-grouped so a failed open cannot spray the hook's stderr.
# It is still best-effort: dedup degrading to a duplicate note is better than a
# non-zero exit from a PostToolUse hook.
mkdir -p "$STATE_DIR" 2>/dev/null || true
{ printf '%s\n' "$FULL_SHA" > "$SHA_FILE"; } 2>/dev/null || true
