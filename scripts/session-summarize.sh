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
DAILY_SUBPATH=$(grep '^daily_path:' "$CONFIG_FILE" | head -1 | sed 's/^daily_path:[[:space:]]*//' | sed 's|\.\./||g; s|^\./||; s|^/||; s|/$||')
: "${DAILY_SUBPATH:=Daily}"
RESOLVED_VAULT=$(cd "$VAULT_PATH" && pwd -P)
DAILY_DIR="${RESOLVED_VAULT}/${DAILY_SUBPATH}"
RESOLVED_DAILY=$(mkdir -p "$DAILY_DIR" && cd "$DAILY_DIR" && pwd -P)
case "$RESOLVED_DAILY" in
  "${RESOLVED_VAULT}/"*|"${RESOLVED_VAULT}") ;;
  *)
    DAILY_SUBPATH="Daily"
    DAILY_DIR="${RESOLVED_VAULT}/Daily"
    ;;
esac
DAILY_NOTE="${DAILY_DIR}/${TODAY}.md"

ROUTING_RULES=$(awk '/^## Routing Rules/ { in_section=1; next } /^## / && in_section { exit } in_section { print }' "$CONFIG_FILE" | head -20)
TAXONOMY=$(awk '/^## Project Taxonomy/ { in_section=1; next } /^## / && in_section { exit } in_section { print }' "$CONFIG_FILE" | head -20)
INTENT_HIGH_SCORE=$(grep '^intent_high_score:' "$CONFIG_FILE" | head -1 | sed 's/^intent_high_score:[[:space:]]*//')
INTENT_MARGIN=$(grep '^intent_margin:' "$CONFIG_FILE" | head -1 | sed 's/^intent_margin:[[:space:]]*//')
CAPTURE_HIGH_SCORE=$(grep '^capture_high_score:' "$CONFIG_FILE" | head -1 | sed 's/^capture_high_score:[[:space:]]*//')
: "${INTENT_HIGH_SCORE:=0.70}"
: "${INTENT_MARGIN:=0.15}"
: "${CAPTURE_HIGH_SCORE:=0.70}"

PROMPT=$(cat <<'PROMPT_EOF'
You are a session-to-Obsidian note converter. You receive a Claude Code conversation transcript (JSON).

Your ONLY output must be valid markdown for a single Obsidian session note. No preamble, no explanation, no code fences — just the raw markdown content starting with the YAML frontmatter.

Rules:
1. If the conversation is trivial (< 5 substantive messages, no code/decisions/debugging), output exactly: SKIP
2. Infer session intent and capture action from concrete transcript signals before routing.
3. Determine the domain from the routing rules below and pick the correct vault subfolder.
4. Generate a slug from the main topics (lowercase, dashes, no dates).

Session intent values:
- execution: code/work/task session; produced or changed artifacts
- research: papers, synthesis, claims, experiments, literature, source-backed comparisons
- planning: roadmap, spec, decision analysis, implementation plan, project sequencing
- reflection: trajectory, positioning, identity, personal synthesis
- operations: customer/admin/business/accounting/course logistics
- scratch: casual/trivial/non-durable conversation

Capture action values:
- none: no durable capture
- daily_only: daily-scoped note or lightweight daily mention only
- project_note: normal project/session note
- substrate_update: research-substrate claim/evidence/literature/experiment update is warranted
- decision_record: durable decision or plan record is warranted

Scoring rules:
- Assign a numeric score from 0.00 to 1.00 for session_intent and capture_action.
- session_intent confidence is high if score >= INTENT_HIGH_SCORE_PLACEHOLDER and the margin over the next plausible option is >= INTENT_MARGIN_PLACEHOLDER.
- capture_action confidence is high if score >= CAPTURE_HIGH_SCORE_PLACEHOLDER and the margin over the next plausible option is >= INTENT_MARGIN_PLACEHOLDER.
- confidence is medium if score >= 0.45 but either margin is close or key evidence is mixed.
- confidence is low otherwise.
- Use concrete evidence bullets: user verbs, referenced artifacts, outputs produced, explicit destination hints, and domain terms.
- Explicit user instructions win over inference (e.g. "daily only", "update research substrate", "leave a note in NRX").
- If the best capture action is none, output SKIP.
- If this is an ambiguous non-interactive autosave where a human confirmation would be needed, still write the note but set capture_needs_confirmation: true and pick the safer durable action (usually daily_only or project_note, not substrate_update).

Output format (when not SKIP):
---
date: YYYY-MM-DD
domain: <domain>
vault_folder: <relative path from vault root, e.g. Awesome Motive/sessions/>
slug: <topic-slug>
session_intent: <execution|research|planning|reflection|operations|scratch>
session_intent_score: <0.00-1.00>
session_intent_confidence: <high|medium|low>
capture_action: <none|daily_only|project_note|substrate_update|decision_record>
capture_action_score: <0.00-1.00>
capture_action_confidence: <high|medium|low>
capture_needs_confirmation: <true|false>
tags: [<relevant tags>]
---

# <Descriptive Title>

## Capture Inference
- **Session intent:** `<value>` (`<confidence>`, `<score>`)
- **Capture action:** `<value>` (`<confidence>`, `<score>`)
- **Evidence:**
  - <concrete signal 1>
  - <concrete signal 2>
  - <concrete signal 3>
- **Needs confirmation:** `<true|false>` with one short reason when true

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
PROMPT="${PROMPT/INTENT_HIGH_SCORE_PLACEHOLDER/$INTENT_HIGH_SCORE}"
PROMPT="${PROMPT/INTENT_MARGIN_PLACEHOLDER/$INTENT_MARGIN}"
PROMPT="${PROMPT/CAPTURE_HIGH_SCORE_PLACEHOLDER/$CAPTURE_HIGH_SCORE}"

RESULT=$(claude --print --bare --system-prompt "$PROMPT" --max-budget-usd 0.10 < "$TMPFILE" 2>/dev/null) || exit 1

TRIMMED=$(printf '%s' "$RESULT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$TRIMMED" ] || [ "$TRIMMED" = "SKIP" ]; then
  exit 0
fi

VAULT_FOLDER=$(printf '%s\n' "$RESULT" | grep '^vault_folder:' | head -1 | sed 's/^vault_folder:[[:space:]]*//')
SLUG=$(printf '%s\n' "$RESULT" | grep '^slug:' | head -1 | sed 's/^slug:[[:space:]]*//')
SESSION_INTENT=$(printf '%s\n' "$RESULT" | grep '^session_intent:' | head -1 | sed 's/^session_intent:[[:space:]]*//')
CAPTURE_ACTION=$(printf '%s\n' "$RESULT" | grep '^capture_action:' | head -1 | sed 's/^capture_action:[[:space:]]*//')

: "${VAULT_FOLDER:=Inbox/}"
: "${SLUG:=session-note}"
: "${SESSION_INTENT:=scratch}"
: "${CAPTURE_ACTION:=project_note}"

# Sanitize: strip path traversal, restrict slug to safe characters
VAULT_FOLDER=$(printf '%s' "$VAULT_FOLDER" | sed 's|\.\./||g; s|^\./||; s|^/||')
SLUG=$(printf '%s' "$SLUG" | sed 's/[^a-z0-9-]//g')
: "${SLUG:=session-note}"
case "$SESSION_INTENT" in
  execution|research|planning|reflection|operations|scratch) ;;
  *) SESSION_INTENT="scratch" ;;
esac
case "$CAPTURE_ACTION" in
  none|daily_only|project_note|substrate_update|decision_record) ;;
  *) CAPTURE_ACTION="project_note" ;;
esac
if [ "$CAPTURE_ACTION" = "none" ]; then
  exit 0
fi

# Ensure trailing slash on vault_folder
case "$VAULT_FOLDER" in
  */) ;;
  *)  VAULT_FOLDER="${VAULT_FOLDER}/" ;;
esac

if [ "$CAPTURE_ACTION" = "daily_only" ]; then
  VAULT_FOLDER="${DAILY_SUBPATH}/"
fi

NOTE_DIR="${VAULT_PATH}/${VAULT_FOLDER}"

# Resolve and verify the target stays inside the vault
RESOLVED_VAULT=$(cd "$VAULT_PATH" && pwd -P)
mkdir -p "$NOTE_DIR"
RESOLVED_DIR=$(cd "$NOTE_DIR" && pwd -P)
case "$RESOLVED_DIR" in
  "${RESOLVED_VAULT}/"*|"${RESOLVED_VAULT}") ;;
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
