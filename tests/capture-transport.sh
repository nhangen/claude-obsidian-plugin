#!/usr/bin/env bash
# capture-transport.sh — the Stop hook honors the capture_transport gate.
# Regression coverage for issue #254 stage one: the automatic legacy writer can
# be switched off (and unknown values refuse to write) without uninstalling the
# plugin, while explicit --capture stays reversible.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/obsidian-transport-test-XXXXXX")"
trap 'rm -rf "$CASE_DIR"' EXIT

BIN_DIR="${CASE_DIR}/bin"
VAULT_DIR="${CASE_DIR}/vault"
mkdir -p "$BIN_DIR" "$VAULT_DIR/Daily" "$VAULT_DIR/Inbox"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "${BIN_DIR}/nohup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 10 ] && [ "$1" = "python3" ] && [ "$2" = "${EXPECTED_SUMMARIZER:?}" ] || {
  printf 'stub: unexpected nohup argv:' >&2
  printf ' <%s>' "$@" >&2
  printf '\n' >&2
  exit 99
}
printf '%s\n' "$@" > "${NOHUP_ARGS:?}"
EOF
chmod +x "${BIN_DIR}/nohup"

write_config() {
  cat > "${CASE_DIR}/config.md" <<EOF
---
vault_path: ${VAULT_DIR}
daily_path: Daily/
auto_save: true
keeper_autostart: false
${1:-}
---

## Project Taxonomy

| Domain | Vault path | Precedence | Notes |
|--------|------------|------------|-------|
| Daily | Daily/ | 50 | Daily |
EOF
}

write_transcript() {
  # Over 200 bytes so the size floor in session-save.sh passes.
  cat > "$1" <<'EOF'
{"type":"user","message":{"content":"The session transport gate must stop automatic legacy capture without uninstalling anything. Fill this line with enough prose to clear the two-hundred-byte transcript floor comfortably."}}
{"type":"assistant","message":{"content":"Second content line, also long enough to keep the fixture clear of the small-transcript guard: the gate decides which writer owns automatic session capture, not whether words exist to summarize."}}
EOF
}

# run_hook STATE_DIR [script args...] — sources session-save.sh like a Stop hook.
run_hook() {
  local state_dir="$1"
  shift
  local err_file="${CASE_DIR}/stderr.txt"
  rm -f "${CASE_DIR}/nohup-args.txt" "$err_file"
  write_transcript "${CASE_DIR}/hook-transcript.jsonl"
  printf '{"transcript_path":"%s"}' "${CASE_DIR}/hook-transcript.jsonl" |
    env PATH="${BIN_DIR}:$PATH" \
      HOME="${CASE_DIR}/home" \
      XDG_CONFIG_HOME="${CASE_DIR}/xdg" \
      XDG_STATE_HOME="${state_dir}" \
      OBSIDIAN_LOCAL_MD="${CASE_DIR}/config.md" \
      TMPDIR="${CASE_DIR}" \
      NOHUP_ARGS="${CASE_DIR}/nohup-args.txt" \
      EXPECTED_SUMMARIZER="${ROOT_DIR}/scripts/lib/session-capture.py" \
      bash -c "trap wait EXIT; source \"\$0\"" \
      "${ROOT_DIR}/scripts/session-save.sh" "$@" 2>"$err_file" \
    || fail "hook exited non-zero for [$*]"
  python3 - "$state_dir/claude-obsidian/capture-ownership/admission.lock" <<'PY'
import fcntl, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
if path.exists():
    with path.open("r+") as stream:
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(.01)
PY
  printf '%s' "$err_file"
}

# Positive controls: an absent key and an explicit legacy value both launch.
write_config ""
run_hook "${CASE_DIR}/state-absent" >/dev/null
[ -f "${CASE_DIR}/nohup-args.txt" ] || fail "absent: no summarizer launch (positive control failed)"
write_config "capture_transport: legacy"
run_hook "${CASE_DIR}/state-legacy" >/dev/null
[ -f "${CASE_DIR}/nohup-args.txt" ] || fail "legacy: no summarizer launch"

test_disabled_stop() {
  write_config 'capture_transport: disabled'
  ERR="$(run_hook "${CASE_DIR}/state-disabled")"
  [ ! -f "${CASE_DIR}/nohup-args.txt" ] || fail "disabled: summarizer launched on Stop"
  grep -q 'automatic session capture is OFF (capture_transport: disabled)' "$ERR" \
    || fail "disabled: silent shutdown (stderr: $ERR)"
  [ ! -d "${CASE_DIR}/state-disabled/claude-obsidian/session-capture" ] \
    || fail "disabled: capture state was touched after the gate"
}

test_unknown() {
  write_config 'capture_transport: immediate'
  ERR="$(run_hook "${CASE_DIR}/state-unknown")"
  [ ! -f "${CASE_DIR}/nohup-args.txt" ] || fail "unknown: summarizer launched"
  grep -q 'unknown capture_transport immediate' "$ERR" \
    || fail "unknown: typo not named on stderr (stderr: $ERR)"
  [ ! -d "${CASE_DIR}/state-unknown/claude-obsidian/session-capture" ] \
    || fail "unknown: capture state touched for a typo"
}

# A configured empty value must be rejected like a typo, not silently treated
# as the legacy default (#255 review): the reader's absent/present status is
# the only distinction, and present-but-empty is operator error.
test_empty_configured() {
  for fixture in 'capture_transport:' 'capture_transport: ""'; do
    write_config "$fixture"
    ERR="$(run_hook "${CASE_DIR}/state-empty")"
    [ ! -f "${CASE_DIR}/nohup-args.txt" ] \
      || fail "empty [$fixture]: summarizer launched"
    grep -q 'unknown capture_transport <empty>' "$ERR" \
      || fail "empty [$fixture]: not named on stderr (stderr: $ERR)"
    [ ! -d "${CASE_DIR}/state-empty/claude-obsidian/session-capture" ] \
      || fail "empty [$fixture]: capture state touched"
    # Explicit invocation is refused too: a bad enum never becomes a writer.
    run_hook "${CASE_DIR}/state-empty-xcap" --capture >/dev/null
    [ ! -f "${CASE_DIR}/nohup-args.txt" ] \
      || fail "empty [$fixture]: explicit capture ran on a rejected value"
  done
}

test_disabled_capture_honored() {
  write_config 'capture_transport: disabled'
  run_hook "${CASE_DIR}/state-xcap" --capture >/dev/null
  [ -f "${CASE_DIR}/nohup-args.txt" ] || fail "disabled + --capture: explicit capture was refused"
}

test_bootstrap_pin() {
  grep -F '[ "$TRANSPORT" != disabled ]' "${ROOT_DIR}/scripts/session-save.sh" >/dev/null \
    || fail "keeper bootstrap is not gated on the transport (a retired writer must not re-arm it)"
}

test_disabled_stop
test_unknown
test_empty_configured
test_disabled_capture_honored
test_bootstrap_pin

echo "ok"
