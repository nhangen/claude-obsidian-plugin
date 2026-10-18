#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDACTOR_PATH="${REDACTOR_PATH:-${ROOT_DIR}/scripts/lib/redact-secrets.sh}"
SCRIPTS_PATH="${SCRIPTS_PATH:-${ROOT_DIR}/scripts}"
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

[ "$1" = "--print" ] || unexpected "$@"
case "${EXPECT_AUTH_MODE:-}" in
  login) [ "$2" != "--bare" ] || unexpected "$@" ;;
  api) [ "$2" = "--bare" ] || unexpected "$@" ;;
  *) unexpected "$@" ;;
esac
for arg in "$@"; do
  [ "$arg" != "--no-session-persistence" ] || unexpected "$@"
done

printf '%s\n' "$@" > "${CALL_ARGS:?}"
printf '%s' "${OBSIDIAN_SUMMARIZING:-unset}" > "${CALL_ENV:?}"
cat > "${CALL_STDIN:?}"
[ "${CLAUDE_EXIT_CODE:-0}" -eq 0 ] || exit "$CLAUDE_EXIT_CODE"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"SKIP"}'
EOF
chmod +x "${BIN_DIR}/claude"

cat > "${BIN_DIR}/nohup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 8 ] &&
  [ "$1" = "python3" ] &&
  [ "$2" = "${EXPECTED_SUMMARIZER:?}" ] &&
  [ "$4" = "${EXPECTED_CONFIG:?}" ] &&
  [ "$5" = "${EXPECTED_VAULT:?}" ] &&
  [ -f "$3" ] && [ -s "$3" ] && [ -f "$6" ] || {
    printf 'stub: unexpected nohup argv:' >&2
    printf ' <%s>' "$@" >&2
    printf '\n' >&2
    exit 99
  }
printf '%s\n' "$@" > "${NOHUP_ARGS:?}"
EOF
chmod +x "${BIN_DIR}/nohup"

write_transcript() {
  cat > "$1" <<'EOF'
{"password":"fake secret phrase with spaces","note":"KEEP adjacent plain field"}
{"password":"fake secret with \"quoted\" text and \\ backslash","next":"KEEP plain boundary"}
{"type":"user","message":{"content":"nested {\"password\":\"fake escaped phrase with spaces and \\\"quoted\\\" text plus \\\\ backslash\",\"next\":\"KEEP escaped boundary\"}"}}
{"type":"user","message":{"content":"{\"password\":\"fake \\\"quoted\\\", remaining secret phrase\",\"note\":\"KEEP parsed boundary\"}"}}
{"type":"user","message":{"content":"fragment \"password\":\"fake fragment secret phrase\" end"}}
{"type":"user","message":{"content":"my creds: {\"clientId\": \"393798153876298382\", \"keyId\": \"FAKE-KEY-ID-1234\", \"key\": \"-----BEGIN PRIVATE KEY-----\\nFAKEFAKEFAKEFAKE\\n-----END PRIVATE KEY-----\\n\"}"}}
{"type":"user","message":{"content":"tokens glpat-FAKETOKENabcdefghij0123 and ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE12 and Authorization: Bearer FAKEBEARERabcdefghijklmnopqrstu"}}
{"type":"user","message":{"content":"ISTARI_AUTH_TOKEN=FAKEvalue12345678 PASSWORD: hunter2hunter2 jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.FAKESIGNATUREabcdef"}}
{"type":"user","message":{"content":"KEEP system bacbf587-0932-4c75-93d8-58513ff65bbd and ordinary key and token prose"}}
EOF
}

assert_redacted() {
  local file="$1"
  local leak_pattern='fake secret phrase|fake secret with|fake escaped phrase|remaining secret phrase|fake fragment secret phrase|FAKEFAKE|FAKE-KEY|393798153876298382|FAKETOKEN|FAKEBEARER|FAKEvalue|hunter2|FAKESIGNATURE|ghp_FAKE|PRIVATE KEY-----\\n'
  if grep -qE "$leak_pattern" "$file"; then
    grep -nE "$leak_pattern" "$file" >&2
    fail "redactor left a complete credential value in $file"
  fi
  grep -qF '"password":"[REDACTED]","note":"KEEP adjacent plain field"' "$file" \
    || fail "plain JSON credential redaction consumed an adjacent field"
  grep -qF '"password":"[REDACTED]","next":"KEEP plain boundary"' "$file" \
    || fail "plain escaped credential redaction consumed an adjacent field"
  grep -qF '\"password\":\"[REDACTED]\",\"next\":\"KEEP escaped boundary\"' "$file" \
    || fail "JSONL-escaped credential redaction consumed an adjacent field"
  grep -qF 'fragment \"password\":\"[REDACTED]\" end' "$file" \
    || fail "JSONL-escaped credential fragment was not fully redacted"
  python3 - "$file" <<'PY' || fail "redacted nested credential JSON is invalid or incomplete"
import json
import sys

found = False
with open(sys.argv[1], encoding="utf-8") as stream:
    for line in stream:
        outer = json.loads(line)
        content = outer.get("message", {}).get("content", "")
        if "KEEP parsed boundary" not in content:
            continue
        nested = json.loads(content)
        if nested != {"password": "[REDACTED]", "note": "KEEP parsed boundary"}:
            raise AssertionError(nested)
        found = True
if not found:
    raise AssertionError("nested boundary fixture not found")
PY
  grep -qF 'bacbf587-0932-4c75-93d8-58513ff65bbd' "$file" \
    || fail "redactor removed a plain UUID"
  grep -qF 'ordinary key and token prose' "$file" \
    || fail "redactor removed ordinary prose"
}

assert_model_redacted() {
  python3 - "$1" <<'MODEL_PY' || fail "model input was not extracted and redacted"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows[0]["kind"] == "extraction_metadata"
text = "\n".join(row.get("text", "") for row in rows[1:])
assert "fake escaped phrase" not in text and "remaining secret phrase" not in text
assert "FAKEFAKE" not in text and "hunter2" not in text
assert "KEEP parsed boundary" in text and "ordinary key and token prose" in text
assert "[REDACTED]" in text
MODEL_PY
}

run_summarizer() {
  local scripts_dir="$1"
  shift
  write_transcript "${CASE_DIR}/transcript.jsonl"
  rm -f "${CASE_DIR}/args.txt" "${CASE_DIR}/env.txt" "${CASE_DIR}/stdin.txt"
  env PATH="${BIN_DIR}:$PATH" \
    XDG_STATE_HOME="${CASE_DIR}/state" \
    CALL_ARGS="${CASE_DIR}/args.txt" \
    CALL_ENV="${CASE_DIR}/env.txt" \
    CALL_STDIN="${CASE_DIR}/stdin.txt" \
    "$@" \
    bash "${scripts_dir}/session-summarize.sh" \
      "${CASE_DIR}/transcript.jsonl" "${CASE_DIR}/config.md" "$VAULT_DIR"
}

test_redactor() {
  write_transcript "${CASE_DIR}/redact.jsonl"
  bash "$REDACTOR_PATH" "${CASE_DIR}/redact.jsonl" \
    || fail "redactor exited non-zero on a normal file"
  assert_redacted "${CASE_DIR}/redact.jsonl"
  if bash "$REDACTOR_PATH" "${CASE_DIR}/does-not-exist" 2>/dev/null; then
    fail "redactor should fail on a missing file"
  fi
}

test_login_auth() {
  run_summarizer "$SCRIPTS_PATH" \
    EXPECT_AUTH_MODE=login ANTHROPIC_API_KEY= \
    || fail "login-auth summarizer invocation failed"
  [ "$(cat "${CASE_DIR}/env.txt")" = "1" ] \
    || fail "OBSIDIAN_SUMMARIZING was not set for the nested claude"
  assert_model_redacted "${CASE_DIR}/stdin.txt"
}

test_api_auth() {
  run_summarizer "$SCRIPTS_PATH" \
    EXPECT_AUTH_MODE=api ANTHROPIC_API_KEY=sk-test-not-a-real-key-000000 \
    || fail "API-key summarizer invocation failed"
  grep -qx -- '--bare' "${CASE_DIR}/args.txt" \
    || fail "API-key path no longer uses --bare"
  assert_model_redacted "${CASE_DIR}/stdin.txt"
}

test_failure_propagation() {
  if run_summarizer "${ROOT_DIR}/scripts" \
    EXPECT_AUTH_MODE=api ANTHROPIC_API_KEY=sk-test-not-a-real-key-000000 CLAUDE_EXIT_CODE=23; then
    fail "summarizer hid a model failure"
  fi
  [ -f "${CASE_DIR}/stdin.txt" ] || fail "model failure test did not reach the model boundary"

  cp -R "${ROOT_DIR}/scripts" "${CASE_DIR}/scripts-broken"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${CASE_DIR}/scripts-broken/lib/redact-secrets.sh"
  if run_summarizer "${CASE_DIR}/scripts-broken" \
    EXPECT_AUTH_MODE=api ANTHROPIC_API_KEY=sk-test-not-a-real-key-000000; then
    fail "summarizer hid a redactor failure"
  fi
  [ ! -f "${CASE_DIR}/args.txt" ] || fail "claude ran even though redaction failed"
}

run_hook() {
  rm -f "${CASE_DIR}/nohup-args.txt"
  printf '{"transcript_path":"%s"}' "${CASE_DIR}/hook-transcript.jsonl" |
    env PATH="${BIN_DIR}:$PATH" \
      HOME="${CASE_DIR}/home" \
      XDG_CONFIG_HOME="${CASE_DIR}/xdg" \
      XDG_STATE_HOME="${CASE_DIR}/state" \
      OBSIDIAN_LOCAL_MD="${CASE_DIR}/config.md" \
      TMPDIR="${CASE_DIR}" \
      NOHUP_ARGS="${CASE_DIR}/nohup-args.txt" \
      EXPECTED_SUMMARIZER="${ROOT_DIR}/scripts/lib/session-capture.py" \
      EXPECTED_CONFIG="${CASE_DIR}/config.md" \
      EXPECTED_VAULT="$VAULT_DIR" \
      "$@" bash -c "trap wait EXIT; source \"\$0\"" "${ROOT_DIR}/scripts/session-save.sh"
}

test_recursion_guard() {
  mkdir -p "${CASE_DIR}/home" "${CASE_DIR}/xdg"
  write_transcript "${CASE_DIR}/hook-transcript.jsonl"

  run_hook ANTHROPIC_API_KEY=
  [ -f "${CASE_DIR}/nohup-args.txt" ] \
    || fail "positive control: autosave did not launch the summarizer"

  run_hook ANTHROPIC_API_KEY= OBSIDIAN_SUMMARIZING=1
  [ ! -f "${CASE_DIR}/nohup-args.txt" ] \
    || fail "autosave ran inside the summarizer's own session"
}

case "${1:-all}" in
  redactor) test_redactor ;;
  login) test_login_auth ;;
  api) test_api_auth ;;
  failures) test_failure_propagation ;;
  recursion) test_recursion_guard ;;
  all)
    test_redactor
    test_login_auth
    test_api_auth
    test_failure_propagation
    test_recursion_guard
    ;;
  *)
    printf 'usage: %s [redactor|login|api|failures|recursion|all]\n' "$0" >&2
    exit 2
    ;;
esac

echo "ok"
