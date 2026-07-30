#!/usr/bin/env bash
# Exercises how scripts/commit-capture.sh reads the payload: the command-word
# gate, the failure guard's scope, and which repository the hook addresses.
#
# These are real git repositories, not a stub. The stub in
# commit-capture-detection.sh strips `-C <dir>` before matching argv, so it
# cannot see which repo the hook pointed git at — the mini panel on PR #48
# showed that reverting `git -C "$REPO_DIR"` to bare `git` left that whole
# suite green. Repo identity has to be asserted against real repos.
#
# Every case below was verified to fail before the corresponding fix.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/commit-capture.sh"

WORK=""
STATE_HOME=""
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cleanup() {
  [ -n "$WORK" ] && chmod -R u+w "$WORK" 2>/dev/null
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$STATE_HOME" ] && rm -rf "$STATE_HOME"
  return 0
}
trap cleanup EXIT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-parse-XXXXXX")"
STATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-parse-state-XXXXXX")"

# A repo with one fresh commit and a known remote.
mkrepo() {
  local dir="$1" remote="$2" subject="${3:-seed commit}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  # Fixtures must not run the developer's global hooks (an identity gate lives
  # there and would block every seed commit).
  git -C "$dir" config core.hooksPath /dev/null
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Tester
  git -C "$dir" remote add origin "$remote"
  : > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -q -m "$subject"
}

# The post-hook only captures when a PreToolUse snapshot says HEAD moved *in this
# repo*, so every positive case needs one naming the repo the hook will resolve.
# Rather than hard-code that (these cases are precisely about which repo gets
# resolved), ask the production functions — the same ones the real pre-hook uses.
# `sha=` is a value no real HEAD can equal, which keeps these cases about payload
# parsing and repo resolution; the gate itself has its own suite in
# commit-capture-head-gate.sh.
resolved_root_for() {
  local from="$1" payload="$2"
  (
    cd "$from" || exit 0
    . "${ROOT_DIR}/scripts/lib/commit-capture-parse.sh"
    cmd="$(cc_json_value "$payload" '"command"')"
    cwd="$(cc_json_value "$payload" '"cwd"')"
    cc_invokes_commit "$cmd" || exit 0
    d="$(cc_find_repo_dir "$cwd")" || exit 0
    git -C "$d" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$d"
  )
}

snapshot_for() {
  local payload="$1" sha="${2:-}" root="${3:-}" key
  # `none` is what the pre-hook records for an unborn HEAD, and it is what these
  # fixtures actually are: a repo whose seed commit is its first. A fabricated sha
  # would fail the post-hook's ancestry check — correctly, since no such object
  # exists — and every case here would go quiet for the wrong reason.
  [ -n "$sha" ] || sha=none
  key="$(
    . "${ROOT_DIR}/scripts/lib/commit-capture-parse.sh"
    cc_snapshot_key "$payload"
  )"
  mkdir -p "${STATE_HOME:?}/claude-obsidian/pre-commit-head"
  printf 'sha=%s\nroot=%s\nintent=\n' "$sha" "$root" \
    > "${STATE_HOME}/claude-obsidian/pre-commit-head/${key}"
}

# Run the hook from a chosen working directory with a chosen payload.
# $1 = cwd to run from, $2 = full JSON payload.
run_from() {
  local from="$1" payload="$2"
  rm -rf "${STATE_HOME:?}/claude-obsidian"
  snapshot_for "$payload" "" "$(resolved_root_for "$from" "$payload")"
  ( cd "$from" && printf '%s' "$payload" | XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null ) || true
}

# Build a payload with a JSON-escaped command, an optional cwd, and optional
# response text. Quotes in the command arrive escaped, exactly as they do in a
# real hook payload — that is the whole point of several cases here.
payload() {
  local cmd="$1" cwd="${2:-}" resp="${3:-}"
  local esc="$cmd"
  esc="${esc//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\n'/\\n}"
  printf '{'
  [ -n "$cwd" ] && printf '"cwd":"%s",' "$cwd"
  printf '"tool_input":{"command":"%s"},"tool_response":{"stdout":"%s"}}' "$esc" "$resp"
}

REAL="$WORK/real"
mkrepo "$REAL" "https://gitlab.com/altamira2/mtf-builder.git"

# --- 1. a quoted path before `commit` must not kill the gate -----------------
# The payload is JSON, so every `"` arrives as `\"`. Truncating the command at
# the first quote dropped `cd "<worktree>" && git commit` — this project's own
# documented workflow.
SPACED="$WORK/my repo"
mkrepo "$SPACED" "git@github.com:nhangen/spaced.git" "spaced commit"
OUT="$(run_from "$WORK" "$(payload "cd \"$SPACED\" && git commit -q -m x")")"
case "$OUT" in
  *"org_repo=nhangen/spaced"*) : ;;
  *) fail "quoted cd path was dropped (escaped-quote truncation)"$'\n'"got: ${OUT:-<empty>}" ;;
esac

OUT="$(run_from "$REAL" "$(payload 'echo "staging" && git commit -q -m x' "$REAL")")"
case "$OUT" in
  *hash=*) : ;;
  *) fail "a quoted argument before the commit segment dropped the capture"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# --- 2. multi-line and compound commands ------------------------------------
# A newline in the payload is the two characters \n, which was not a separator,
# so the whole command collapsed into one segment. master captured these.
for cmd in \
  "git add -A"$'\n'"git commit -q -m x" \
  'if true; then git commit -q -m x; fi' \
  'for f in a; do git commit -q -m x; done' \
  'git  commit -q -m x' \
  'GIT_AUTHOR_DATE=2020-01-01 git commit -q -m x' \
  '/usr/bin/git commit -q -m x' ; do
  OUT="$(run_from "$REAL" "$(payload "$cmd" "$REAL")")"
  case "$OUT" in
    *hash=*) : ;;
    *) fail "command shape was dropped: $cmd"$'\n'"got: ${OUT:-<empty>}" ;;
  esac
done

# --- 2b. things that only MENTION a commit must stay silent ------------------
# Decoding the payload made newlines real separators, which is what fixed the
# multi-line case above — and it also exposed heredoc bodies to the gate for the
# first time. `cat <<EOF` / `git commit -q` / `EOF` is a document, not a command.
for cmd in \
  'git log --grep=commit' \
  'echo commit' \
  'grep -rn commit .' \
  'npm run commit' \
  "cat <<EOF"$'\n'"git commit -q -m x"$'\n'"EOF" \
  "cat <<-'END'"$'\n'"  git commit -q"$'\n'"  END" ; do
  OUT="$(run_from "$REAL" "$(payload "$cmd" "$REAL")")"
  [ -z "$OUT" ] || fail "a mention of a commit was captured: $cmd"$'\n'"got: $OUT"
done
# …but a heredoc used to SUPPLY the message is a real commit.
OUT="$(run_from "$REAL" "$(payload "git commit -q -F - <<EOF"$'\n'"subject line"$'\n'"EOF" "$REAL")")"
case "$OUT" in
  *hash=*) : ;;
  *) fail "a commit reading its message from a heredoc was dropped"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# --- 2c. a large command must not stall the hook -----------------------------
# The first cut of the JSON decoder walked the value one character at a time and
# took ~11 seconds on a 4 KB command. This hook runs after every Bash call.
BIG="echo $(awk 'BEGIN{while(i++<4000)printf "a"}') && git commit -q -m x"
START=$(date +%s)
OUT="$(run_from "$REAL" "$(payload "$BIG" "$REAL")")"
ELAPSED=$(( $(date +%s) - START ))
case "$OUT" in
  *hash=*) : ;;
  *) fail "a 4KB command was not captured"$'\n'"got: ${OUT:-<empty>}" ;;
esac
[ "$ELAPSED" -le 3 ] || fail "hook took ${ELAPSED}s on a 4KB command; payload parsing is not linear enough for a PostToolUse hook"

# --- 3. no text — command, subject, or response — decides success ------------
# There used to be a list of failure phrases matched against the payload, and a
# `--dry-run` check. Both are gone: whether a commit landed is HEAD_before vs
# HEAD_after. These cases pin that no guard word can suppress a real capture.
GUARDED="$WORK/guarded"
mkrepo "$GUARDED" "git@github.com:nhangen/guarded.git" "fix: swallow fatal: on rebase"
OUT="$(run_from "$GUARDED" "$(payload 'git commit -q -F -' "$GUARDED")")"
case "$OUT" in
  *hash=*) : ;;
  *) fail "a commit whose subject contains 'fatal:' was dropped"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# The guard word has to appear in the COMMAND for these to mean anything. A
# subject supplied via `-F -` never reaches the payload, so asserting on one
# proves nothing about what the hook reads.
for cmd in \
  'git commit -q -m "fix: error: handling"' \
  'git commit -q -m "guard fatal: paths"' \
  'git commit -q -m "stop Aborting early"' \
  'git commit -q -m "explain nothing to commit"' \
  'git commit -q -m "add --dry-run flag"' \
  "git commit -q -m 'add --dry-run flag'" ; do
  OUT="$(run_from "$REAL" "$(payload "$cmd" "$REAL")")"
  case "$OUT" in
    *hash=*) : ;;
    *) fail "a guard word in the command text suppressed a real capture: $cmd"$'\n'"got: ${OUT:-<empty>}" ;;
  esac
done

for subj in 'fix: handle error: prefix' 'feat: add --dry-run flag' 'docs: the Aborting path'; do
  D="$WORK/subj-$RANDOM"
  mkrepo "$D" "git@github.com:nhangen/subj.git" "$subj"
  OUT="$(run_from "$D" "$(payload 'git commit -q -F -' "$D")")"
  case "$OUT" in
    *hash=*) : ;;
    *) fail "commit subject '$subj' was treated as a failure"$'\n'"got: ${OUT:-<empty>}" ;;
  esac
done

# Guard words in the RESPONSE no longer decide anything either. This response is
# the one git prints when nothing was committed — but the snapshot says HEAD
# moved, so the capture stands. A "nothing to commit" call in the field leaves
# HEAD where it was and is rejected by the gate, not by this text.
OUT="$(run_from "$REAL" "$(payload 'git commit -q -F -' "$REAL" 'nothing to commit, working tree clean')")"
case "$OUT" in
  *hash=*) : ;;
  *) fail "response text still suppresses a capture the HEAD gate accepted"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# A dry run cannot move HEAD, so a snapshot equal to the current tip rejects it —
# and that same snapshot proves the rejection is the gate's, not a flag check.
SNAP_HEAD="$(git -C "$REAL" rev-parse HEAD)"
# The root has to be what the hook will resolve — rev-parse output, not the path
# string — or it reads as a snapshot from a different repo.
SNAP_ROOT="$(git -C "$REAL" rev-parse --show-toplevel)"
DRY_PAYLOAD="$(payload 'git commit --dry-run' "$REAL")"
rm -rf "${STATE_HOME:?}/claude-obsidian"
snapshot_for "$DRY_PAYLOAD" "$SNAP_HEAD" "$SNAP_ROOT"
OUT="$( cd "$REAL" && printf '%s' "$DRY_PAYLOAD" | XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null )" || true
[ -z "$OUT" ] || fail "--dry-run was captured"$'\n'"got: $OUT"

# --- 4. repo resolution addresses the right repository ----------------------
# The hook runs with its own cwd, which is not the repo the commit happened in.
OTHER="$WORK/other"
mkrepo "$OTHER" "git@github.com:someoneelse/OTHER.git" "other commit"

# payload cwd wins over the hook's own cwd
OUT="$(run_from "$OTHER" "$(payload 'git commit -q -m x' "$REAL")")"
case "$OUT" in
  *"org_repo=altamira2/mtf-builder"*) : ;;
  *) fail "payload cwd ignored; hook read its own cwd"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# an absolute `cd` in the command wins over the payload cwd
OUT="$(run_from "$WORK" "$(payload "cd $REAL && git commit -q -m x" "$OTHER")")"
case "$OUT" in
  *"org_repo=altamira2/mtf-builder"*) : ;;
  *) fail "absolute cd target ignored"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# a RELATIVE `cd` resolves against the payload cwd, not the hook's cwd.
# With a same-named decoy in the hook's cwd this captured the decoy's commit,
# message and org_repo, and would have filed the note under someoneelse/DECOY.
mkdir -p "$WORK/decoyhome"
mkrepo "$WORK/decoyhome/nested" "git@github.com:someoneelse/DECOY.git" "DECOY COMMIT"
mkrepo "$REAL/nested" "https://gitlab.com/altamira2/nested.git" "real nested commit"
OUT="$(run_from "$WORK/decoyhome" "$(payload 'cd nested && git commit -q -m x' "$REAL")")"
case "$OUT" in
  *"org_repo=someoneelse/DECOY"*) fail "relative cd resolved against the hook's cwd and captured the wrong repository"$'\n'"got: $OUT" ;;
  *"org_repo=altamira2/nested"*) : ;;
  *) fail "relative cd did not resolve against the payload cwd"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# `git -C <dir>` is where git actually ran
OUT="$(run_from "$OTHER" "$(payload "git -C \"$REAL\" commit -q -m x" "$OTHER")")"
case "$OUT" in
  *"org_repo=altamira2/mtf-builder"*) : ;;
  *) fail "git -C <dir> was not honored by repo resolution"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# a `cd` to somewhere that is not a repo must not be accepted
mkdir -p "$WORK/plain"
OUT="$(run_from "$REAL" "$(payload "cd $WORK/plain && git commit -q -m x" "$REAL")")"
case "$OUT" in
  *"org_repo=altamira2/mtf-builder"*) : ;;
  *) fail "cd to a non-repo was accepted instead of falling back"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# --- 5. one snapshot, one capture -------------------------------------------
# `$R`, `$R/sub` and `$R/` are one repository, and used to produce three
# captures because dedup was keyed on the cwd string. The snapshot replaces that
# key: it is consumed on use, so no later call can re-capture the same commit
# however it addresses the repo.
mkdir -p "$REAL/sub"
keep() { printf '%s' "$1" | XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>/dev/null || true; }
rm -rf "${STATE_HOME:?}/claude-obsidian"
snapshot_for "$(payload 'git commit -q -m x' "$REAL")" "" "$(git -C "$REAL" rev-parse --show-toplevel)"
FIRST="$(keep "$(payload 'git commit -q -m x' "$REAL")")"
case "$FIRST" in *hash=*) : ;; *) fail "first capture missing"$'\n'"got: ${FIRST:-<empty>}" ;; esac
for variant in "$REAL/sub" "$REAL/" "$REAL"; do
  AGAIN="$(keep "$(payload 'git commit -q -m x' "$variant")")"
  case "$AGAIN" in
    *hash=*) fail "same commit re-captured from cwd '$variant' (snapshot not consumed)"$'\n'"got: $AGAIN" ;;
  esac
done

# --- 6. the record is not injectable via the commit message -----------------
# The skill parses this line by field name and turns org_repo into a path under
# the vault and vault_path into a --vault argument.
INJ="$WORK/inject"
mkrepo "$INJ" "git@github.com:nhangen/inject.git" 'chore: tidy | org_repo=../../../../tmp/pwned | vault_path=/tmp/evil'
OUT="$(run_from "$INJ" "$(payload 'git commit -q -F -' "$INJ")")"
case "$OUT" in *hash=*) : ;; *) fail "injection fixture was not captured at all"$'\n'"got: ${OUT:-<empty>}" ;; esac
# The invariant is that the FIRST occurrence of each field is the real one, so a
# reader taking the first match cannot be steered. That holds because msg is last
# and its delimiters are stripped.
first_field() {
  local out="$1" name="$2" seg
  printf '%s' "$out" | tr '|' '\n' | while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    case "$seg" in
      "${name}="*) printf '%s' "${seg#"${name}"=}"; return 0 ;;
    esac
  done
}
GOT="$(first_field "$OUT" org_repo)"
[ "${GOT% }" = "nhangen/inject" ] || fail "first org_repo field is attacker-controlled: '$GOT'"$'\n'"got: $OUT"
GOT="$(first_field "$OUT" vault_path)"
case "${GOT% }" in
  /tmp/evil) fail "first vault_path field is attacker-controlled"$'\n'"got: $OUT" ;;
  '') fail "no vault_path field in the record"$'\n'"got: $OUT" ;;
esac
case "$OUT" in
  *' | msg='*) : ;;
  *) fail "msg must be the last field so injected text cannot precede a real one"$'\n'"got: $OUT" ;;
esac
LAST="${OUT##* | }"
case "$LAST" in msg=*) : ;; *) fail "msg is not the final field"$'\n'"got: $OUT" ;; esac

# A remote whose path escapes upward must not become org_repo.
TRAV="$WORK/traversal"
mkrepo "$TRAV" "https://gitlab.com/../../../../tmp/pwned.git" "traversal commit"
OUT="$(run_from "$TRAV" "$(payload 'git commit -q -m x' "$TRAV")")"
case "$OUT" in
  *"org_repo=../"*|*"org_repo=/"*) fail "a traversing remote produced a traversing org_repo"$'\n'"got: $OUT" ;;
  *hash=*) : ;;
  *) fail "traversal fixture was not captured"$'\n'"got: ${OUT:-<empty>}" ;;
esac

# --- 7. a deep repo path must not break the state write ----------------------
# Slugging the raw path as the state key exceeded NAME_MAX in a deep worktree:
# the open failed, the shell error went to the hook's stderr, and the gate
# silently stopped working. The key is a bounded digest for that reason.
DEEP="$WORK/$(printf 'd%.0s' $(seq 1 60))/$(printf 'e%.0s' $(seq 1 60))/$(printf 'f%.0s' $(seq 1 60))/repo"
mkrepo "$DEEP" "git@github.com:nhangen/deep.git" "deep commit"
DEEP_PAYLOAD="$(payload 'git commit -q -m x' "$DEEP")"
rm -rf "${STATE_HOME:?}/claude-obsidian"
snapshot_for "$DEEP_PAYLOAD" "" "$(git -C "$DEEP" rev-parse --show-toplevel)"
ERR="$(mktemp)"
OUT="$( cd "$DEEP" && printf '%s' "$DEEP_PAYLOAD" | XDG_STATE_HOME="$STATE_HOME" bash "$SCRIPT" 2>"$ERR" )" || true
case "$OUT" in *hash=*) : ;; *) fail "deep-path repo was not captured"$'\n'"got: ${OUT:-<empty>}" ;; esac
grep -q 'File name too long' "$ERR" && { rm -f "$ERR"; fail "state key is unbounded; the hook printed a shell error"; }
rm -f "$ERR"

# --- 8. a missing lib must be reported, not silently swallowed ---------------
# resolve-config.sh was sourced unguarded: the hook printed two shell errors and
# an empty vault_path, which the skill skips silently — a capture lost with no
# visible cause. Same requirement now applies to the parsing lib the two hooks
# share: without it the hook cannot even read the payload.
COPY="$WORK/plugincopy"
mkdir -p "$COPY/scripts/lib"
cp "$SCRIPT" "$COPY/scripts/commit-capture.sh"
cp "${ROOT_DIR}/scripts/lib/commit-capture-parse.sh" "$COPY/scripts/lib/"
COPY_PAYLOAD="$(payload 'git commit -q -m x' "$REAL")"
rm -rf "${STATE_HOME:?}/claude-obsidian"
snapshot_for "$COPY_PAYLOAD" "" "$(git -C "$REAL" rev-parse --show-toplevel)"
ERR="$(mktemp)"
OUT="$( cd "$REAL" && printf '%s' "$COPY_PAYLOAD" | XDG_STATE_HOME="$STATE_HOME" bash "$COPY/scripts/commit-capture.sh" 2>"$ERR" )" || true
case "$OUT" in
  *hash=*) rm -f "$ERR"; fail "hook emitted a record with no config library present"$'\n'"got: $OUT" ;;
esac
# Reported on stdout, which is the channel a hook exiting 0 actually surfaces.
case "$OUT" in
  *'vault_path unresolved'*) : ;;
  *) rm -f "$ERR"; fail "a missing config library was not reported"$'\n'"got: ${OUT:-<empty>}" ;;
esac
[ ! -s "$ERR" ] || { local_err="$(cat "$ERR")"; rm -f "$ERR"; fail "hook wrote to stderr, where nothing reads it: $local_err"; }
rm -f "$ERR"

# Without the parsing lib the hook has no decoder at all. It must say so rather
# than exit 0 like a non-commit call.
BARE="$WORK/barecopy"
mkdir -p "$BARE/scripts"
cp "$SCRIPT" "$BARE/scripts/commit-capture.sh"
ERR="$(mktemp)"
OUT="$( cd "$REAL" && printf '%s' "$COPY_PAYLOAD" | XDG_STATE_HOME="$STATE_HOME" bash "$BARE/scripts/commit-capture.sh" 2>"$ERR" )" || true
case "$OUT" in
  *hash=*) rm -f "$ERR"; fail "hook emitted a record with no parsing library"$'\n'"got: $OUT" ;;
esac
case "$OUT" in
  *'commit-capture-parse.sh'*) : ;;
  *) bare_err="$(cat "$ERR")"; rm -f "$ERR"; fail "a missing parsing library was not reported"$'\n'"stdout: ${OUT:-<empty>}"$'\n'"stderr: ${bare_err:-<empty>}" ;;
esac
rm -f "$ERR"

# A present-but-broken lib must be reported too, not swallowed as a non-commit call.
BROKEN="$WORK/brokencopy"
mkdir -p "$BROKEN/scripts/lib"
cp "$SCRIPT" "$BROKEN/scripts/commit-capture.sh"
printf 'this is not valid shell (\n' > "$BROKEN/scripts/lib/commit-capture-parse.sh"
OUT="$( cd "$REAL" && printf '%s' "$COPY_PAYLOAD" | XDG_STATE_HOME="$STATE_HOME" bash "$BROKEN/scripts/commit-capture.sh" 2>/dev/null )" || true
case "$OUT" in
  *hash=*) fail "hook emitted a record with a broken parsing library"$'\n'"got: $OUT" ;;
  *'failed to load'*) : ;;
  *) fail "a broken parsing library was not reported"$'\n'"got: ${OUT:-<empty>}" ;;
esac

printf 'ok   commit-capture-parsing.sh (payload parsing, repo resolution, record integrity)\n'
