#!/usr/bin/env bash
# Autosave: login-compatible summarizer invocation, secret redaction, recursion guard.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/obsidian-autosave-test-XXXXXX")"
trap 'rm -rf "$CASE_DIR"' EXIT

BIN_DIR="${CASE_DIR}/bin"
VAULT_DIR="${CASE_DIR}/vault"
mkdir -p "$BIN_DIR" "$VAULT_DIR/Daily" "$VAULT_DIR/Inbox"

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

# Fake claude: records its argv, a marker env var, and the stdin it was given.
cat > "${BIN_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s\n' "$@"
} > "${CALL_ARGS:?}"
printf '%s' "${OBSIDIAN_SUMMARIZING:-unset}" > "${CALL_ENV:?}"
cat > "${CALL_STDIN:?}"
printf 'SKIP\n'
EOF
chmod +x "${BIN_DIR}/claude"

write_transcript() {
  cat > "$1" <<'EOF'
{"type":"user","message":{"content":"my creds: {\"clientId\": \"393798153876298382\", \"keyId\": \"FAKE-KEY-ID-1234\", \"key\": \"-----BEGIN PRIVATE KEY-----\\nFAKEFAKEFAKEFAKE\\n-----END PRIVATE KEY-----\\n\"}"}}
{"type":"user","message":{"content":"tokens glpat-FAKETOKENabcdefghij0123 and ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE12 and Authorization: Bearer FAKEBEARERabcdefghijklmnopqrstu"}}
{"type":"user","message":{"content":"ISTARI_AUTH_TOKEN=FAKEvalue12345678 PASSWORD: hunter2hunter2 jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.FAKESIGNATUREabcdef"}}
{"type":"user","message":{"content":"KEEP system bacbf587-0932-4c75-93d8-58513ff65bbd and the words key and token"}}
EOF
}

LEAK_PATTERN='FAKEFAKE|FAKE-KEY|393798153876298382|FAKETOKEN|FAKEBEARER|FAKEvalue|hunter2|FAKESIGNATURE|ghp_FAKE|PRIVATE KEY-----\\n'

run_summarizer() {
  # $1 = scripts dir to run from; remaining args are extra env assignments
  local scripts_dir="$1"; shift
  write_transcript "${CASE_DIR}/transcript.jsonl"
  rm -f "${CASE_DIR}/args.txt" "${CASE_DIR}/env.txt" "${CASE_DIR}/stdin.txt"
  env PATH="${BIN_DIR}:$PATH" \
    CALL_ARGS="${CASE_DIR}/args.txt" CALL_ENV="${CASE_DIR}/env.txt" CALL_STDIN="${CASE_DIR}/stdin.txt" \
    "$@" \
    bash "${scripts_dir}/session-summarize.sh" \
      "${CASE_DIR}/transcript.jsonl" "${CASE_DIR}/config.md" "$VAULT_DIR" || true
}

# --- 1. redactor on its own -------------------------------------------------
write_transcript "${CASE_DIR}/redact.jsonl"
bash "${ROOT_DIR}/scripts/lib/redact-secrets.sh" "${CASE_DIR}/redact.jsonl" \
  || fail "redactor exited non-zero on a normal file"
if grep -qE "$LEAK_PATTERN" "${CASE_DIR}/redact.jsonl"; then
  grep -nE "$LEAK_PATTERN" "${CASE_DIR}/redact.jsonl" >&2
  fail "redactor left a secret in the transcript"
fi
grep -qF 'bacbf587-0932-4c75-93d8-58513ff65bbd' "${CASE_DIR}/redact.jsonl" \
  || fail "redactor removed a plain UUID"
grep -qF 'the words key and token' "${CASE_DIR}/redact.jsonl" \
  || fail "redactor removed ordinary prose"
if bash "${ROOT_DIR}/scripts/lib/redact-secrets.sh" "${CASE_DIR}/does-not-exist" 2>/dev/null; then
  fail "redactor should fail on a missing file"
fi

# --- 2. no API key: login-compatible flags, no --bare, marker set ----------
run_summarizer "${ROOT_DIR}/scripts" ANTHROPIC_API_KEY=
[ -f "${CASE_DIR}/args.txt" ] || fail "claude was not invoked without an API key"
grep -qx -- '--bare' "${CASE_DIR}/args.txt" && fail "--bare used without an API key (breaks login auth)"
grep -qx -- '--setting-sources' "${CASE_DIR}/args.txt" || fail "expected --setting-sources without an API key"
grep -qx -- '--tools' "${CASE_DIR}/args.txt" || fail "expected --tools without an API key"
[ "$(cat "${CASE_DIR}/env.txt")" = "1" ] || fail "OBSIDIAN_SUMMARIZING was not set for the nested claude"
if grep -qE "$LEAK_PATTERN" "${CASE_DIR}/stdin.txt"; then
  fail "a secret reached the summarizer's stdin"
fi

# --- 3. API key present: original --bare path ------------------------------
run_summarizer "${ROOT_DIR}/scripts" ANTHROPIC_API_KEY=sk-test-not-a-real-key-000000
grep -qx -- '--bare' "${CASE_DIR}/args.txt" || fail "expected --bare when ANTHROPIC_API_KEY is set"

# --- 4. fail closed: a failing redactor means claude is never called -------
cp -R "${ROOT_DIR}/scripts" "${CASE_DIR}/scripts-broken"
printf '#!/usr/bin/env bash\nexit 1\n' > "${CASE_DIR}/scripts-broken/lib/redact-secrets.sh"
run_summarizer "${CASE_DIR}/scripts-broken" ANTHROPIC_API_KEY=
[ ! -f "${CASE_DIR}/args.txt" ] || fail "claude ran even though redaction failed"

# --- 5. autosave hook: recursion guard ------------------------------------
# Positive control first: without the guard the hook reaches the summarizer.
write_transcript "${CASE_DIR}/hook-transcript.jsonl"
HOOK_JSON="{\"transcript_path\":\"${CASE_DIR}/hook-transcript.jsonl\"}"
run_hook() {
  rm -f "${CASE_DIR}/args.txt" "${CASE_DIR}/env.txt" "${CASE_DIR}/stdin.txt"
  printf '%s' "$HOOK_JSON" | env PATH="${BIN_DIR}:$PATH" HOME="${CASE_DIR}/home" XDG_CONFIG_HOME="${CASE_DIR}/xdg" \
    OBSIDIAN_LOCAL_MD="${CASE_DIR}/config.md" TMPDIR="${CASE_DIR}" \
    CALL_ARGS="${CASE_DIR}/args.txt" CALL_ENV="${CASE_DIR}/env.txt" CALL_STDIN="${CASE_DIR}/stdin.txt" \
    "$@" bash "${ROOT_DIR}/scripts/session-save.sh"
}
mkdir -p "${CASE_DIR}/home" "${CASE_DIR}/xdg"

run_hook ANTHROPIC_API_KEY= >/dev/null 2>&1 || true
for _ in $(seq 1 40); do [ -f "${CASE_DIR}/args.txt" ] && break; sleep 0.25; done
[ -f "${CASE_DIR}/args.txt" ] || fail "positive control: autosave did not reach the summarizer"

run_hook ANTHROPIC_API_KEY= OBSIDIAN_SUMMARIZING=1 >/dev/null 2>&1 || true
sleep 2
[ ! -f "${CASE_DIR}/args.txt" ] || fail "autosave ran inside the summarizer's own session (recursion guard missing)"

echo "ok"
