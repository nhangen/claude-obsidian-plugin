#!/usr/bin/env bash
# Exercises scripts/commit-capture.sh's vault_path YAML parse block.
# Regression coverage for inline-vault_path inlining (issue #12) — reverting
# the parse block must fail this suite.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/commit-capture.sh"
GIT_BIN_DIR=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Stub git so commit-capture treats us as inside a real commit and we can
# control hash/msg/branch/files without touching a real repo.
make_git_stub() {
  GIT_BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-git-XXXXXX")"
  cat > "${GIT_BIN_DIR}/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-C" ]; then shift 2; fi
case "$*" in
  "log -1 --format=%ct") date +%s ;;
  "rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "rev-parse --short HEAD") echo abc1234 ;;
  "log -1 --pretty=format:%s") echo "test commit" ;;
  "rev-parse --abbrev-ref HEAD") echo nh/feat/test ;;
  "diff --name-only HEAD~1..HEAD") echo foo.txt ;;
  "remote get-url origin") echo "git@github.com:nhangen/test.git" ;;
  "rev-parse --show-toplevel") echo "/tmp/test-repo" ;;
  *) echo "" ;;
esac
exit 0
STUB
  chmod +x "${GIT_BIN_DIR}/git"
}

cleanup_git_stub() {
  [ -n "$GIT_BIN_DIR" ] && rm -rf "$GIT_BIN_DIR"
  GIT_BIN_DIR=""
}

# Each case gets a fresh XDG_STATE_HOME holding one PreToolUse HEAD snapshot: the
# hook captures only when the snapshot shows HEAD moved, and it consumes the
# snapshot, so a shared state dir would make every case after the first return
# empty. It also keeps the suite from writing to the host's real state dir.
# `sha=` is a value the stubbed HEAD cannot equal, and `root=` is the toplevel the
# stub reports — a pair the real pre-hook could have written. These cases are about
# the vault_path parse, not the gate.
new_state_home() {
  local dir key
  dir="$(mktemp -d)"
  key="$(
    . "${ROOT_DIR}/scripts/lib/commit-capture-parse.sh"
    cc_snapshot_key "$1"
  )"
  mkdir -p "${dir}/claude-obsidian/pre-commit-head"
  printf 'sha=1111111111111111111111111111111111111111\nroot=/tmp/test-repo\nintent=\n' \
    > "${dir}/claude-obsidian/pre-commit-head/${key}"
  printf '%s' "$dir"
}
# Run the script with a given config file and capture the printf output.
# Returns the captured vault_path field value via stdout. Empty string if the
# field is empty or the script took the silent-skip path.
run_case() {
  local config_file="$1"
  local plugin_root="${2:-}"
  local input='{"tool_input":{"command":"git commit -m foo"},"tool_response":{"stdout":"[main abc1234] foo\n"}}'
  local out
  if [ -n "$plugin_root" ]; then
    out=$(CLAUDE_PLUGIN_ROOT="$plugin_root" XDG_STATE_HOME="$(new_state_home "$input")" PATH="${GIT_BIN_DIR}:$PATH" bash "$SCRIPT" <<< "$input")
  else
    out=$(env -u CLAUDE_PLUGIN_ROOT XDG_STATE_HOME="$(new_state_home "$input")" PATH="${GIT_BIN_DIR}:$PATH" bash "$SCRIPT" <<< "$input")
  fi
  # Extract vault_path=<value>. It is no longer the last field — msg moved to the
  # end so a commit subject cannot inject a field ahead of a real one — so stop
  # at the next delimiter rather than running to end of line.
  printf '%s' "$out" | sed -n 's/.* | vault_path=\(.*\) | msg=.*$/\1/p'
}

# Run and capture the raw output line (for asserting fields beyond vault_path).
run_case_raw() {
  local config_file="$1"
  local plugin_root="${2:-}"
  local input='{"tool_input":{"command":"git commit -m foo"},"tool_response":{"stdout":"[main abc1234] foo\n"}}'
  if [ -n "$plugin_root" ]; then
    CLAUDE_PLUGIN_ROOT="$plugin_root" XDG_STATE_HOME="$(new_state_home "$input")" PATH="${GIT_BIN_DIR}:$PATH" bash "$SCRIPT" <<< "$input"
  else
    env -u CLAUDE_PLUGIN_ROOT XDG_STATE_HOME="$(new_state_home "$input")" PATH="${GIT_BIN_DIR}:$PATH" bash "$SCRIPT" <<< "$input"
  fi
}

# Isolate config resolution: the resolver prefers $OBSIDIAN_LOCAL_MD and the
# stable XDG path over CLAUDE_PLUGIN_ROOT. Point XDG_CONFIG_HOME at an empty dir
# and clear the override so these cases deterministically exercise the
# plugin-root config the test controls, regardless of the host's real config.
ISOLATED_XDG="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-xdg-XXXXXX")"
export XDG_CONFIG_HOME="$ISOLATED_XDG"
unset OBSIDIAN_LOCAL_MD

make_git_stub
trap 'cleanup_git_stub; rm -rf "$ISOLATED_XDG"' EXIT

PASS_COUNT=0

# ----- Case 1: happy path with tilde expansion -----
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-XXXXXX")"
printf -- '---\nvault_path: ~/Documents/Obsidian\n---\n' > "${CASE_DIR}/obsidian.local.md"
GOT=$(run_case "${CASE_DIR}/obsidian.local.md" "$CASE_DIR")
EXPECTED="${HOME}/Documents/Obsidian"
[ "$GOT" = "$EXPECTED" ] || fail "case1 (tilde): got '$GOT' want '$EXPECTED'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 2: unset CLAUDE_PLUGIN_ROOT -> empty vault_path, no error -----
GOT=$(run_case "" "")
[ -z "$GOT" ] || fail "case2 (unset root): got '$GOT' want empty"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 3: missing config file -> empty vault_path, no error -----
EMPTY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-empty-XXXXXX")"
GOT=$(run_case "" "$EMPTY_DIR")
[ -z "$GOT" ] || fail "case3 (missing file): got '$GOT' want empty"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 4: empty vault_path: value -> empty -----
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-XXXXXX")"
printf -- '---\nvault_path:\n---\n' > "${CASE_DIR}/obsidian.local.md"
GOT=$(run_case "${CASE_DIR}/obsidian.local.md" "$CASE_DIR")
[ -z "$GOT" ] || fail "case4 (empty value): got '$GOT' want empty"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 5: CRLF line endings stripped -----
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-XXXXXX")"
printf -- '---\r\nvault_path: /Users/test/vault\r\n---\r\n' > "${CASE_DIR}/obsidian.local.md"
GOT=$(run_case "${CASE_DIR}/obsidian.local.md" "$CASE_DIR")
[ "$GOT" = "/Users/test/vault" ] || fail "case5 (CRLF): got '$GOT' want '/Users/test/vault'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 6: inline comment stripped -----
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-XXXXXX")"
printf -- '---\nvault_path: /Users/test/vault  # main vault\n---\n' > "${CASE_DIR}/obsidian.local.md"
GOT=$(run_case "${CASE_DIR}/obsidian.local.md" "$CASE_DIR")
[ "$GOT" = "/Users/test/vault" ] || fail "case6 (inline comment): got '$GOT' want '/Users/test/vault'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 7: double-quoted value -----
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-XXXXXX")"
printf -- '---\nvault_path: "/Users/test/My Vault"\n---\n' > "${CASE_DIR}/obsidian.local.md"
GOT=$(run_case "${CASE_DIR}/obsidian.local.md" "$CASE_DIR")
[ "$GOT" = "/Users/test/My Vault" ] || fail "case7 (double-quoted): got '$GOT' want '/Users/test/My Vault'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 8: single-quoted value -----
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-XXXXXX")"
printf -- "---\nvault_path: '/Users/test/Vault'\n---\n" > "${CASE_DIR}/obsidian.local.md"
GOT=$(run_case "${CASE_DIR}/obsidian.local.md" "$CASE_DIR")
[ "$GOT" = "/Users/test/Vault" ] || fail "case8 (single-quoted): got '$GOT' want '/Users/test/Vault'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 9: output preserves all metadata fields with vault_path appended -----
CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-vp-XXXXXX")"
printf -- '---\nvault_path: /Users/test/v\n---\n' > "${CASE_DIR}/obsidian.local.md"
OUT=$(run_case_raw "${CASE_DIR}/obsidian.local.md" "$CASE_DIR")
case "$OUT" in
  'obsidian-commit-capture: hash='*' | branch='*' | files='*' | org_repo='*' | repo_name='*' | ticket='*' | date='*' | time='*' | vault_path=/Users/test/v | msg='*) ;;
  *) fail "case9 (schema): got '$OUT'" ;;
esac
PASS_COUNT=$((PASS_COUNT + 1))

printf '%d/9 cases passed\n' "$PASS_COUNT"
