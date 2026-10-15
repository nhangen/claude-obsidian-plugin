#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/obsidian-autosave-test-XXXXXX")"
trap 'rm -rf "$CASE_DIR"' EXIT

BIN_DIR="${CASE_DIR}/bin"
VAULT_DIR="${CASE_DIR}/vault"
mkdir -p "$BIN_DIR" "$VAULT_DIR/Daily" "$VAULT_DIR/Inbox"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "${CASE_DIR}/config.md" <<EOF
---
vault_path: ${VAULT_DIR}
daily_path: Daily/
auto_save: true
keeper_autostart: false
---

## Project Taxonomy

| Domain | Vault path | Precedence | Notes |
|--------|------------|------------|-------|
| Daily | Daily/ | 50 | Daily |
| Inbox | Inbox/ | 99 | Fallback |

## Routing Rules

- Ambiguous -> Inbox/
EOF

cat > "${BIN_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

unexpected() {
  printf 'stub: unexpected %s argv:' "${EXPECT_AUTH_MODE:-unset}" >&2
  printf ' <%s>' "$@" >&2
  printf '\n' >&2
  exit 99
}

case "${EXPECT_AUTH_MODE:-}" in
  login)
    [ "$#" -eq 12 ] &&
      [ "$1" = "--print" ] &&
      [ "$2" = "--no-session-persistence" ] &&
      [ "$3" = "--disable-slash-commands" ] &&
      [ "$4" = "--tools" ] &&
      [ -z "$5" ] &&
      [ "$6" = "--strict-mcp-config" ] &&
      [ "$7" = "--setting-sources" ] &&
      [ -z "$8" ] &&
      [ "$9" = "--system-prompt" ] &&
      [ -n "${10}" ] &&
      [ "${11}" = "--max-budget-usd" ] &&
      [ "${12}" = "0.10" ] || unexpected "$@"
    ;;
  api)
    [ "$#" -eq 6 ] &&
      [ "$1" = "--print" ] &&
      [ "$2" = "--bare" ] &&
      [ "$3" = "--system-prompt" ] &&
      [ -n "$4" ] &&
      [ "$5" = "--max-budget-usd" ] &&
      [ "$6" = "0.10" ] || unexpected "$@"
    ;;
  *) unexpected "$@" ;;
esac

printf '%s\n' "$@" > "${CALL_ARGS:?}"
printf '%s' "${OBSIDIAN_SUMMARIZING:-unset}" > "${CALL_ENV:?}"
cat > "${CALL_STDIN:?}"
[ "${CLAUDE_EXIT_CODE:-0}" -eq 0 ] || exit "$CLAUDE_EXIT_CODE"
printf 'SKIP\n'
EOF
chmod +x "${BIN_DIR}/claude"

cat > "${BIN_DIR}/nohup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 5 ] &&
  [ "$1" = "bash" ] &&
  [ "$2" = "${EXPECTED_SUMMARIZER:?}" ] &&
  [ "$4" = "${EXPECTED_CONFIG:?}" ] &&
  [ "$5" = "${EXPECTED_VAULT:?}" ] &&
  [ -f "$3" ] || exit 99
printf '%s\n' "$@" > "${NOHUP_ARGS:?}"
EOF
chmod +x "${BIN_DIR}/nohup"

write_transcript() {
  cat > "$1" <<'EOF'
{"type":"user","message":{"content":"my creds: {\"clientId\": \"393798153876298382\", \"keyId\": \"FAKE-KEY-ID-1234\", \"key\": \"-----BEGIN PRIVATE KEY-----\\nFAKEFAKEFAKEFAKE\\n-----END PRIVATE KEY-----\\n\"}"}}
{"type":"user","message":{"content":"tokens glpat-FAKETOKENabcdefghij0123 and ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE12 and Authorization: Bearer FAKEBEARERabcdefghijklmnopqrstu"}}
{"type":"user","message":{"content":"ISTARI_AUTH_TOKEN=FAKEvalue12345678 PASSWORD: hunter2hunter2 jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.FAKESIGNATUREabcdef"}}
{"type":"user","message":{"content":"KEEP system bacbf587-0932-4c75-93d8-58513ff65bbd and ordinary key and token prose"}}
EOF
}

assert_redacted() {
  local file="$1"
  local leak_pattern='FAKEFAKE|FAKE-KEY|393798153876298382|FAKETOKEN|FAKEBEARER|FAKEvalue|hunter2|FAKESIGNATURE|ghp_FAKE|PRIVATE KEY-----\\n'
  if grep -qE "$leak_pattern" "$file"; then
    grep -nE "$leak_pattern" "$file" >&2
    fail "redactor left a secret in $file"
  fi
  grep -qF 'bacbf587-0932-4c75-93d8-58513ff65bbd' "$file" || fail "redactor removed a plain UUID"
  grep -qF 'ordinary key and token prose' "$file" || fail "redactor removed ordinary prose"
}

run_summarizer() {
  local scripts_dir="$1"
  shift
  write_transcript "${CASE_DIR}/transcript.jsonl"
  rm -f "${CASE_DIR}/args.txt" "${CASE_DIR}/env.txt" "${CASE_DIR}/stdin.txt"
  env PATH="${BIN_DIR}:$PATH" \
    CALL_ARGS="${CASE_DIR}/args.txt" CALL_ENV="${CASE_DIR}/env.txt" CALL_STDIN="${CASE_DIR}/stdin.txt" \
    "$@" bash "${scripts_dir}/session-summarize.sh" \
      "${CASE_DIR}/transcript.jsonl" "${CASE_DIR}/config.md" "$VAULT_DIR"
}

test_redactor() {
  write_transcript "${CASE_DIR}/redact.jsonl"
  bash "${ROOT_DIR}/scripts/lib/redact-secrets.sh" "${CASE_DIR}/redact.jsonl" || fail "redactor failed"
  assert_redacted "${CASE_DIR}/redact.jsonl"
  if bash "${ROOT_DIR}/scripts/lib/redact-secrets.sh" "${CASE_DIR}/does-not-exist" 2>/dev/null; then
    fail "redactor should fail on a missing file"
  fi
}

test_login_auth() {
  run_summarizer "${ROOT_DIR}/scripts" EXPECT_AUTH_MODE=login ANTHROPIC_API_KEY= || fail "login invocation failed"
  [ "$(cat "${CASE_DIR}/env.txt")" = "1" ] || fail "OBSIDIAN_SUMMARIZING was not set"
  assert_redacted "${CASE_DIR}/stdin.txt"
}

test_api_auth() {
  run_summarizer "${ROOT_DIR}/scripts" EXPECT_AUTH_MODE=api ANTHROPIC_API_KEY=sk-test-not-a-real-key-000000 \
    || fail "API-key invocation failed"
  assert_redacted "${CASE_DIR}/stdin.txt"
}

test_failure_propagation() {
  if run_summarizer "${ROOT_DIR}/scripts" EXPECT_AUTH_MODE=api \
    ANTHROPIC_API_KEY=sk-test-not-a-real-key-000000 CLAUDE_EXIT_CODE=23; then
    fail "summarizer hid a model failure"
  fi
  [ -f "${CASE_DIR}/stdin.txt" ] || fail "model failure did not reach the model boundary"

  cp -R "${ROOT_DIR}/scripts" "${CASE_DIR}/scripts-broken"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${CASE_DIR}/scripts-broken/lib/redact-secrets.sh"
  if run_summarizer "${CASE_DIR}/scripts-broken" EXPECT_AUTH_MODE=api \
    ANTHROPIC_API_KEY=sk-test-not-a-real-key-000000; then
    fail "summarizer hid a redactor failure"
  fi
  [ ! -f "${CASE_DIR}/args.txt" ] || fail "claude ran after redaction failed"
}

run_hook() {
  rm -f "${CASE_DIR}/nohup-args.txt"
  printf '{"transcript_path":"%s"}' "${CASE_DIR}/hook-transcript.jsonl" |
    env PATH="${BIN_DIR}:$PATH" HOME="${CASE_DIR}/home" XDG_CONFIG_HOME="${CASE_DIR}/xdg" \
      OBSIDIAN_LOCAL_MD="${CASE_DIR}/config.md" TMPDIR="${CASE_DIR}" \
      NOHUP_ARGS="${CASE_DIR}/nohup-args.txt" \
      EXPECTED_SUMMARIZER="${ROOT_DIR}/scripts/session-summarize.sh" \
      EXPECTED_CONFIG="${CASE_DIR}/config.md" EXPECTED_VAULT="$VAULT_DIR" \
      "$@" bash -c "trap wait EXIT; source \"\$0\"" "${ROOT_DIR}/scripts/session-save.sh"
}

test_recursion_guard() {
  mkdir -p "${CASE_DIR}/home" "${CASE_DIR}/xdg"
  write_transcript "${CASE_DIR}/hook-transcript.jsonl"
  run_hook ANTHROPIC_API_KEY=
  [ -f "${CASE_DIR}/nohup-args.txt" ] || fail "positive control did not launch summarizer"
  run_hook ANTHROPIC_API_KEY= OBSIDIAN_SUMMARIZING=1
  [ ! -f "${CASE_DIR}/nohup-args.txt" ] || fail "recursion guard failed"
}

test_redactor
test_login_auth
test_api_auth
test_failure_propagation
test_recursion_guard
echo "ok"
