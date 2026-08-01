#!/usr/bin/env bash
# commit-meta.sh — emit one commit-capture record for a commit that already happened.
#
# Claude Code gets this record from the PostToolUse hook. Cursor and Codex have
# no hook channel, so their integration docs used to tell the agent to rebuild
# the metadata inline with `git rev-parse` / `git log` / `git remote get-url`.
# Every one of those copies omitted the userinfo strip, so a remote carrying a
# token (https://oauth2:TOKEN@host/org/repo.git) put that token into org_repo,
# which is written to a synced note's `repo:` frontmatter. That is the defect
# that got scripts/commit-detect.sh deleted; the docs kept it alive.
#
# So this is deliberately NOT a second implementation. It resolves nothing
# itself: org_repo comes from cc_org_repo() and vault_path from
# resolve-config.sh — the same functions the hook calls. It exists so the
# harnesses have something to call instead of something to restate.
#
# Usage:
#   commit-meta.sh [-C <dir>] [<commit-ish>]     # default: HEAD in $PWD
#
# Prints one line on stdout, the same shape the hook emits (minus the
# `obsidian-commit-capture: ` prefix, which is the hook's transport, not part of
# the record):
#
#   hash=<h> | branch=<b> | files=<f> | org_repo=<o> | repo_name=<r> | ticket=<t> | date=<d> | time=<ti> | vault_path=<v> | msg=<m>
#
# Exit 0 with the line on success. Exit non-zero with a reason on stderr when
# the repo, the commit, or vault_path cannot be resolved — never a partial line,
# because a caller that appends a half-resolved record writes to the wrong place.

set -eu

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

die() { printf 'commit-meta: %s\n' "$1" >&2; exit 1; }
require_record_field() {
  cc_record_field_is_safe "$2" || die "unsafe $1: record delimiter or newline"
}

GIT_DIR_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] || die "-C requires a directory"; GIT_DIR_ARG="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done

REV="${1:-HEAD}"

GIT() {
  if [ -n "$GIT_DIR_ARG" ]; then git -C "$GIT_DIR_ARG" "$@"; else git "$@"; fi
}

GIT rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git work tree${GIT_DIR_ARG:+ ($GIT_DIR_ARG)}"

HASH="$(GIT rev-parse --short "$REV" 2>/dev/null)" || die "no such commit: $REV"
MSG="$(GIT log -1 --pretty=format:'%s' "$REV" 2>/dev/null)" || MSG=""
BRANCH="$(GIT rev-parse --abbrev-ref HEAD 2>/dev/null)" || BRANCH=""
FILES="$(GIT diff --name-only "${REV}^!" 2>/dev/null | tr '\n' ',' | sed 's/,$//')" || FILES=""
REMOTE="$(GIT remote get-url origin 2>/dev/null)" || REMOTE=""

# The remote is read here and handed straight to cc_org_repo, which strips
# userinfo before splitting. Do not interpolate $REMOTE into output, a path, or
# a log line anywhere in this script — it is the value that may hold a token.
MAIN_ROOT="$(GIT rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || MAIN_ROOT=""
MAIN_ROOT="${MAIN_ROOT%/.git}"
REPO_NAME="${MAIN_ROOT##*/}"
REPO_NAME="${REPO_NAME%.git}"
: "${REPO_NAME:=unknown}"

[ -f "${SCRIPT_DIR}/lib/commit-capture-parse.sh" ] \
  || die "missing lib/commit-capture-parse.sh (reinstall the plugin)"
# shellcheck source=lib/commit-capture-parse.sh
. "${SCRIPT_DIR}/lib/commit-capture-parse.sh"

ORG_REPO="$(cc_org_repo "$REMOTE" "$REPO_NAME")"
case "$ORG_REPO" in
  local/*) ;;
  */*) REPO_NAME="${ORG_REPO##*/}" ;;
esac
require_record_field org_repo "$ORG_REPO"
require_record_field repo_name "$REPO_NAME"

TICKET=""
case "$BRANCH" in
  */[0-9]*)
    DIGITS="${BRANCH##*/}"
    DIGITS="${DIGITS%%[!0-9]*}"
    case "$DIGITS" in
      ''|*[!0-9]*) ;;
      *) TICKET="$DIGITS" ;;
    esac
    ;;
esac

VAULT_PATH=""
if [ -f "${SCRIPT_DIR}/lib/resolve-config.sh" ]; then
  CONFIG="$(bash "${SCRIPT_DIR}/lib/resolve-config.sh" 2>/dev/null)" || CONFIG=""
  if [ -n "$CONFIG" ] && [ -r "$CONFIG" ]; then
    while IFS= read -r line; do
      case "$line" in
        vault_path:*)
          VAULT_PATH="${line#vault_path:}"
          VAULT_PATH="${VAULT_PATH#"${VAULT_PATH%%[![:space:]]*}"}"
          VAULT_PATH="${VAULT_PATH%\"}"; VAULT_PATH="${VAULT_PATH#\"}"
          break
          ;;
      esac
    done < "$CONFIG"
  fi
fi
[ -n "$VAULT_PATH" ] || die "vault_path unresolved (run /obsidian:setup)"
require_record_field vault_path "$VAULT_PATH"

# A newline or a pipe in a commit subject would split one record into two, and
# the second half would be parsed as fields. Flatten both, same as the hook.
scrub_field() { printf '%s' "$1" | tr '\n\r|' '   '; }

# msg last: it is the only field a commit author writes, so nothing resolvable
# into a path may follow it.
printf 'hash=%s | branch=%s | files=%s | org_repo=%s | repo_name=%s | ticket=%s | date=%s | time=%s | vault_path=%s | msg=%s\n' \
  "$HASH" "$(scrub_field "$BRANCH")" "$(scrub_field "$FILES")" "$ORG_REPO" "$REPO_NAME" \
  "$TICKET" "$(date '+%Y-%m-%d')" "$(date '+%H:%M')" "$VAULT_PATH" "$(scrub_field "$MSG")"
