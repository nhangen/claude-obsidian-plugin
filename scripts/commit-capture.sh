#!/usr/bin/env bash
# commit-capture.sh
# PostToolUse command hook. Detects git commits from Bash tool output,
# extracts metadata, and outputs it inline. Non-commit Bash calls exit silently.

set -uo pipefail

INPUT=$(cat)

# --- Quick exit for non-commit commands ---

case "$INPUT" in
  *'"command"'*'git commit'*)
    ;;
  *)
    exit 0
    ;;
esac

case "$INPUT" in
  *'--dry-run'*)
    exit 0
    ;;
esac

case "$INPUT" in
  *'nothing to commit'*|*'nothing added'*|*'Aborting'*|*'"error:'*)
    exit 0
    ;;
esac

case "$INPUT" in
  *'['*'] '*)
    ;;
  *)
    exit 0
    ;;
esac

# --- Extract git metadata ---

HASH=$(git rev-parse --short HEAD 2>/dev/null) || exit 0
MSG=$(git log -1 --pretty=format:'%s' 2>/dev/null) || MSG=""
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH="unknown"
FILES_RAW=$(git diff --name-only HEAD~1..HEAD 2>/dev/null) || FILES_RAW=""
FILES=$(printf '%s' "$FILES_RAW" | tr '\n' ',' | sed 's/,$//')
REMOTE=$(git remote get-url origin 2>/dev/null) || REMOTE="local"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
REPO_NAME=${REPO_ROOT##*/}
: "${REPO_NAME:=unknown}"
TODAY=$(date '+%Y-%m-%d')
NOW=$(date '+%H:%M')

# --- Derive org/repo from remote URL ---

ORG_REPO=""
case "$REMOTE" in
  *@*:*/*)
    ORG_REPO="${REMOTE#*:}"
    ORG_REPO="${ORG_REPO%.git}"
    ;;
  *github.com/*/*)
    ORG_REPO="${REMOTE#*github.com/}"
    ORG_REPO="${ORG_REPO%.git}"
    ;;
  *)
    ORG_REPO="local/$REPO_NAME"
    ;;
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

# --- Output metadata inline for the obsidian-commit-capture skill ---

printf 'obsidian-commit-capture: hash=%s | msg=%s | branch=%s | files=%s | org_repo=%s | repo_name=%s | ticket=%s | date=%s | time=%s\n' \
  "$HASH" "$MSG" "$BRANCH" "$FILES" "$ORG_REPO" "$REPO_NAME" "$TICKET" "$TODAY" "$NOW"
