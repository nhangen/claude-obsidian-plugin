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
DAILY_NOTE="${VAULT_PATH}/Daily/${TODAY}.md"

ROUTING_RULES=$(sed -n '/^## Routing Rules/,/^##/p' "$CONFIG_FILE" | head -20)
TAXONOMY=$(sed -n '/^## Project Taxonomy/,/^##/p' "$CONFIG_FILE" | head -20)

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

if [ -z "$RESULT" ] || [ "$RESULT" = "SKIP" ]; then
  exit 0
fi

VAULT_FOLDER=$(echo "$RESULT" | grep '^vault_folder:' | head -1 | sed 's/^vault_folder:[[:space:]]*//')
SLUG=$(echo "$RESULT" | grep '^slug:' | head -1 | sed 's/^slug:[[:space:]]*//')

: "${VAULT_FOLDER:=Inbox/}"
: "${SLUG:=session-note}"

NOTE_DIR="${VAULT_PATH}/${VAULT_FOLDER}"
mkdir -p "$NOTE_DIR"

NOTE_FILENAME="${TODAY}-${SLUG}.md"
NOTE_PATH="${NOTE_DIR}/${NOTE_FILENAME}"

# Strip the frontmatter vault_folder and slug lines (internal-only metadata)
CLEAN_RESULT=$(echo "$RESULT" | sed '/^vault_folder:/d; /^slug:/d')
printf '%s\n' "$CLEAN_RESULT" > "$NOTE_PATH"

RELATIVE_NOTE_PATH="${VAULT_FOLDER}${NOTE_FILENAME%.md}"
TITLE=$(echo "$RESULT" | grep '^# ' | head -1 | sed 's/^# //')
: "${TITLE:=$SLUG}"

LINK_LINE="- [[${RELATIVE_NOTE_PATH}|${TITLE}]]"

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
