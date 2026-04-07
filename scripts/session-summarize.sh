#!/usr/bin/env bash
# session-summarize.sh
# Background process spawned by session-save.sh.
# Pipes the conversation transcript through `claude --print` for summarization,
# then writes the result to the Obsidian vault and updates the daily note.

set -uo pipefail

TMPFILE="$1"
CONFIG_FILE="$2"
VAULT_PATH="$3"

if [ ! -f "$TMPFILE" ]; then
  exit 1
fi

cleanup() {
  rm -f "$TMPFILE"
}
trap cleanup EXIT

if ! command -v claude &>/dev/null; then
  exit 1
fi

TODAY=$(date '+%Y-%m-%d')
DAILY_SUBPATH=$(grep '^daily_path:' "$CONFIG_FILE" | head -1 | sed 's/^daily_path:[[:space:]]*//' | sed 's|/$||')
: "${DAILY_SUBPATH:=Daily}"
DAILY_NOTE="${VAULT_PATH}/${DAILY_SUBPATH}/${TODAY}.md"

ROUTING_RULES=$(awk '/^## Routing Rules/ { in_section=1; next } /^## / && in_section { exit } in_section { print }' "$CONFIG_FILE" | head -20)
TAXONOMY=$(awk '/^## Project Taxonomy/ { in_section=1; next } /^## / && in_section { exit } in_section { print }' "$CONFIG_FILE" | head -20)

PROMPT=$(cat <<'PROMPT_EOF'
You are a session-to-Obsidian note converter. You receive a Claude Code conversation transcript (JSON).

Your ONLY output must be valid markdown for a single Obsidian session note. No preamble, no explanation, no code fences — just the raw markdown content starting with the YAML frontmatter.

Rules:
1. If the conversation is trivial (< 5 substantive messages, no code/decisions/debugging), output exactly: SKIP
2. Determine the domain from the routing rules below and pick the correct vault subfolder.
3. Generate a slug from the main topics (lowercase, dashes, no dates).

Output format (when not SKIP):
---
date: YYYY-MM-DD
domain: <domain>
vault_folder: <relative path from vault root, e.g. Awesome Motive/sessions/>
slug: <topic-slug>
tags: [<relevant tags>]
---

# <Descriptive Title>

## Summary
- <2-4 bullet points of what was accomplished>

## Key Decisions
- <decisions made, if any>

## Files Changed
- <list of files modified, if any>

## Commits
- <commit hashes and messages, if any>

## Notes
<any other important context>

ROUTING_RULES_PLACEHOLDER
TAXONOMY_PLACEHOLDER
PROMPT_EOF
)

PROMPT="${PROMPT/ROUTING_RULES_PLACEHOLDER/$ROUTING_RULES}"
PROMPT="${PROMPT/TAXONOMY_PLACEHOLDER/$TAXONOMY}"

RESULT=$(claude --print --bare --system-prompt "$PROMPT" --max-budget-usd 0.10 < "$TMPFILE" 2>/dev/null) || exit 1

TRIMMED=$(printf '%s' "$RESULT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$TRIMMED" ] || [ "$TRIMMED" = "SKIP" ]; then
  exit 0
fi

VAULT_FOLDER=$(printf '%s\n' "$RESULT" | grep '^vault_folder:' | head -1 | sed 's/^vault_folder:[[:space:]]*//')
SLUG=$(printf '%s\n' "$RESULT" | grep '^slug:' | head -1 | sed 's/^slug:[[:space:]]*//')

: "${VAULT_FOLDER:=Inbox/}"
: "${SLUG:=session-note}"

# Sanitize: strip path traversal, restrict slug to safe characters
VAULT_FOLDER=$(printf '%s' "$VAULT_FOLDER" | sed 's|\.\./||g; s|^\./||; s|^/||')
SLUG=$(printf '%s' "$SLUG" | sed 's/[^a-z0-9-]//g')
: "${SLUG:=session-note}"

# Ensure trailing slash on vault_folder
case "$VAULT_FOLDER" in
  */) ;;
  *)  VAULT_FOLDER="${VAULT_FOLDER}/" ;;
esac

NOTE_DIR="${VAULT_PATH}/${VAULT_FOLDER}"

# Resolve and verify the target stays inside the vault
RESOLVED_VAULT=$(cd "$VAULT_PATH" && pwd -P)
mkdir -p "$NOTE_DIR"
RESOLVED_DIR=$(cd "$NOTE_DIR" && pwd -P)
case "$RESOLVED_DIR" in
  "${RESOLVED_VAULT}"*) ;;
  *) exit 1 ;;
esac

NOTE_FILENAME="${TODAY}-${SLUG}.md"
NOTE_PATH="${NOTE_DIR}/${NOTE_FILENAME}"

CLEAN_RESULT=$(printf '%s\n' "$RESULT" | sed '/^vault_folder:/d; /^slug:/d')
printf '%s\n' "$CLEAN_RESULT" > "$NOTE_PATH"

RELATIVE_NOTE_PATH="${VAULT_FOLDER}${NOTE_FILENAME%.md}"
TITLE=$(printf '%s\n' "$RESULT" | grep '^# ' | head -1 | sed 's/^# //')
: "${TITLE:=$SLUG}"

LINK_LINE="- [[${RELATIVE_NOTE_PATH}|${TITLE}]]"

mkdir -p "$(dirname "$DAILY_NOTE")"

if [ ! -f "$DAILY_NOTE" ]; then
  cat > "$DAILY_NOTE" <<DAILY_EOF
# ${TODAY}

## Top 3
1.
2.
3.

## Schedule / Time blocks
-

## Tasks
- [ ]

## Notes
-

## Carryover
-

## Session Links
${LINK_LINE}
DAILY_EOF
elif grep -qF "## Session Links" "$DAILY_NOTE"; then
  printf '%s\n' "$LINK_LINE" >> "$DAILY_NOTE"
else
  printf '\n## Session Links\n%s\n' "$LINK_LINE" >> "$DAILY_NOTE"
fi
