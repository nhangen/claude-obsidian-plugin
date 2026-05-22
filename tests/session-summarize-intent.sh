#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TODAY="$(date '+%Y-%m-%d')"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_no_file() {
  [ ! -e "$1" ] || fail "expected no file: $1"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -qF "$pattern" "$file" || fail "expected '$pattern' in $file"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -qF "$pattern" "$file"; then
    fail "did not expect '$pattern' in $file"
  fi
}

setup_case() {
  CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/obsidian-intent-test-XXXXXX")"
  BIN_DIR="${CASE_DIR}/bin"
  VAULT_DIR="${CASE_DIR}/vault"
  mkdir -p "$BIN_DIR" "$VAULT_DIR"

  cat > "${CASE_DIR}/config.md" <<EOF
---
vault_path: ${VAULT_DIR}
daily_path: Daily/
intent_high_score: 0.82
intent_margin: 0.22
capture_high_score: 0.77
---

## Project Taxonomy

| Domain | Vault path | Precedence | Notes |
|--------|------------|------------|-------|
| Research | Projects/Physics-AI-ML/ | 10 | Research |
| Daily | Daily/ | 50 | Daily |
| Inbox | Inbox/ | 99 | Fallback |

## Routing Rules

- Keywords "paper, research, claim" -> Projects/Physics-AI-ML/
- Ambiguous -> Inbox/
EOF

  cat > "${CASE_DIR}/transcript.jsonl" <<'EOF'
{"type":"user","message":{"content":"read these papers and update research substrate"}}
EOF

  cat > "${BIN_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in
    --system-prompt)
      shift
      printf '%s' "$1" > "${PROMPT_CAPTURE:?}"
      ;;
  esac
  shift || true
done
cat >/dev/null
printf '%s\n' "${FAKE_CLAUDE_OUTPUT:?}"
EOF
  chmod +x "${BIN_DIR}/claude"
}

cleanup_case() {
  rm -rf "$CASE_DIR"
}

run_summarizer() {
  PATH="${BIN_DIR}:$PATH" \
    PROMPT_CAPTURE="${CASE_DIR}/prompt.txt" \
    FAKE_CLAUDE_OUTPUT="$1" \
    bash "${ROOT_DIR}/scripts/session-summarize.sh" \
      "${CASE_DIR}/transcript.jsonl" \
      "${CASE_DIR}/config.md" \
      "$VAULT_DIR"
}

test_substrate_metadata_note() {
  setup_case
  trap cleanup_case RETURN

  run_summarizer '---
date: 2026-05-22
domain: Research
vault_folder: Projects/Physics-AI-ML/
slug: ai-scientist-substrate
session_intent: research
session_intent_score: 0.91
session_intent_confidence: high
capture_action: substrate_update
capture_action_score: 0.88
capture_action_confidence: high
capture_needs_confirmation: false
tags: [research]
---

# AI Scientist Substrate

## Capture Inference
- **Session intent:** `research` (`high`, `0.91`)
- **Capture action:** `substrate_update` (`high`, `0.88`)
- **Evidence:**
  - user supplied papers
  - user asked for substrate update
- **Needs confirmation:** `false`

## Summary
- Captured research substrate implications.'

  note="${VAULT_DIR}/Projects/Physics-AI-ML/${TODAY}-ai-scientist-substrate.md"
  daily="${VAULT_DIR}/Daily/${TODAY}.md"
  assert_file "$note"
  assert_file "$daily"
  assert_contains "$note" "session_intent: research"
  assert_contains "$note" "capture_action: substrate_update"
  assert_contains "$note" "## Capture Inference"
  assert_not_contains "$note" "vault_folder:"
  assert_not_contains "$note" "slug:"
  assert_contains "$daily" "[[Projects/Physics-AI-ML/${TODAY}-ai-scientist-substrate|AI Scientist Substrate]]"
  assert_contains "${CASE_DIR}/prompt.txt" "session_intent confidence is high if score >= 0.82"
  assert_contains "${CASE_DIR}/prompt.txt" "capture_action confidence is high if score >= 0.77"
  assert_contains "${CASE_DIR}/prompt.txt" "capture_needs_confirmation"
}

test_scratch_none_skips() {
  setup_case
  trap cleanup_case RETURN

  run_summarizer '---
date: 2026-05-22
domain: Inbox
vault_folder: Inbox/
slug: casual-chat
session_intent: scratch
session_intent_score: 0.95
session_intent_confidence: high
capture_action: none
capture_action_score: 0.92
capture_action_confidence: high
capture_needs_confirmation: false
tags: []
---

# Casual Chat'

  assert_no_file "${VAULT_DIR}/Inbox/${TODAY}-casual-chat.md"
  assert_no_file "${VAULT_DIR}/Daily/${TODAY}.md"
}

test_capture_none_skips_even_when_not_scratch() {
  setup_case
  trap cleanup_case RETURN

  run_summarizer '---
date: 2026-05-22
domain: Research
vault_folder: Projects/Physics-AI-ML/
slug: low-signal-research-mention
session_intent: research
session_intent_score: 0.52
session_intent_confidence: medium
capture_action: none
capture_action_score: 0.81
capture_action_confidence: high
capture_needs_confirmation: false
tags: []
---

# Low Signal Research Mention'

  assert_no_file "${VAULT_DIR}/Projects/Physics-AI-ML/${TODAY}-low-signal-research-mention.md"
  assert_no_file "${VAULT_DIR}/Daily/${TODAY}.md"
}

test_daily_only_routes_to_daily_folder() {
  setup_case
  trap cleanup_case RETURN

  run_summarizer '---
date: 2026-05-22
domain: Inbox
vault_folder: Inbox/
slug: daily-only-note
session_intent: reflection
session_intent_score: 0.60
session_intent_confidence: medium
capture_action: daily_only
capture_action_score: 0.70
capture_action_confidence: medium
capture_needs_confirmation: true
tags: [reflection]
---

# Daily Only Note

## Capture Inference
- **Session intent:** `reflection` (`medium`, `0.60`)
- **Capture action:** `daily_only` (`medium`, `0.70`)
- **Evidence:**
  - ambiguous lightweight reflection
- **Needs confirmation:** `true` because this was non-interactive autosave.

## Summary
- Captured as daily-only.'

  assert_file "${VAULT_DIR}/Daily/${TODAY}-daily-only-note.md"
  assert_no_file "${VAULT_DIR}/Inbox/${TODAY}-daily-only-note.md"
  assert_no_file "${VAULT_DIR}/Inbox"
  assert_contains "${VAULT_DIR}/Daily/${TODAY}-daily-only-note.md" "capture_needs_confirmation: true"
}

test_daily_only_uses_safe_daily_fallback() {
  setup_case
  trap cleanup_case RETURN

  outside_dir="${CASE_DIR}/outside"
  mkdir -p "$outside_dir"
  ln -s "$outside_dir" "${VAULT_DIR}/LinkOut"
  sed -i.bak 's|daily_path: Daily/|daily_path: LinkOut/Day/|' "${CASE_DIR}/config.md"

  run_summarizer '---
date: 2026-05-22
domain: Inbox
vault_folder: Inbox/
slug: daily-fallback-note
session_intent: reflection
session_intent_score: 0.63
session_intent_confidence: medium
capture_action: daily_only
capture_action_score: 0.74
capture_action_confidence: medium
capture_needs_confirmation: true
tags: [reflection]
---

# Daily Fallback Note

## Capture Inference
- **Session intent:** `reflection` (`medium`, `0.63`)
- **Capture action:** `daily_only` (`medium`, `0.74`)
- **Evidence:**
  - unsafe configured daily path fell back
- **Needs confirmation:** `true`

## Summary
- Captured through safe daily fallback.'

  assert_file "${VAULT_DIR}/Daily/${TODAY}-daily-fallback-note.md"
  assert_no_file "${outside_dir}/Day/${TODAY}-daily-fallback-note.md"
}

test_operations_project_note_stays_project_note() {
  setup_case
  trap cleanup_case RETURN

  run_summarizer '---
date: 2026-05-22
domain: Inbox
vault_folder: Inbox/
slug: customer-refund-note
session_intent: operations
session_intent_score: 0.86
session_intent_confidence: high
capture_action: project_note
capture_action_score: 0.79
capture_action_confidence: high
capture_needs_confirmation: false
tags: [operations]
---

# Customer Refund Note

## Capture Inference
- **Session intent:** `operations` (`high`, `0.86`)
- **Capture action:** `project_note` (`high`, `0.79`)
- **Evidence:**
  - customer/admin context
  - durable note requested
- **Needs confirmation:** `false`

## Summary
- Captured operational context.'

  note="${VAULT_DIR}/Inbox/${TODAY}-customer-refund-note.md"
  assert_file "$note"
  assert_contains "$note" "session_intent: operations"
  assert_contains "$note" "capture_action: project_note"
  assert_not_contains "$note" "capture_action: substrate_update"
}

test_planning_decision_record_metadata() {
  setup_case
  trap cleanup_case RETURN

  run_summarizer '---
date: 2026-05-22
domain: Research
vault_folder: Projects/Physics-AI-ML/
slug: substrate-session-policy
session_intent: planning
session_intent_score: 0.82
session_intent_confidence: high
capture_action: decision_record
capture_action_score: 0.78
capture_action_confidence: high
capture_needs_confirmation: false
tags: [planning, decision]
---

# Substrate Session Policy

## Capture Inference
- **Session intent:** `planning` (`high`, `0.82`)
- **Capture action:** `decision_record` (`high`, `0.78`)
- **Evidence:**
  - durable policy decision
  - implementation plan accepted
- **Needs confirmation:** `false`

## Summary
- Captured a planning decision.'

  note="${VAULT_DIR}/Projects/Physics-AI-ML/${TODAY}-substrate-session-policy.md"
  assert_file "$note"
  assert_contains "$note" "session_intent: planning"
  assert_contains "$note" "capture_action: decision_record"
}

test_substrate_metadata_note
test_scratch_none_skips
test_capture_none_skips_even_when_not_scratch
test_daily_only_routes_to_daily_folder
test_daily_only_uses_safe_daily_fallback
test_operations_project_note_stays_project_note
test_planning_decision_record_metadata

printf 'session-summarize intent tests passed\n'
