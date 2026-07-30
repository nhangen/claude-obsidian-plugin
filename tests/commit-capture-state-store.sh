#!/usr/bin/env bash
# The snapshot store's shape (#63): one accessor owns the path, the two hooks
# call it, and the store is state rather than cache on purpose.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-state-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../scripts/lib/commit-capture-parse.sh
. "$ROOT_DIR/scripts/lib/commit-capture-parse.sh"

PAYLOAD='{"tool_name":"Bash","tool_use_id":"toolu_state_1","session_id":"s-1","tool_input":{"command":"git commit -m x","cwd":"/tmp"}}'

# 1. The composed path is exactly dir + key. Anything else means a caller that
#    builds the path from the parts lands somewhere the accessor does not.
XDG_STATE_HOME="$TMP/state"
export XDG_STATE_HOME
DIR="$(cc_snapshot_dir)"
KEY="$(cc_snapshot_key "$PAYLOAD")"
FILE="$(cc_snapshot_file "$PAYLOAD")"
[ -n "$KEY" ] || fail "cc_snapshot_key returned nothing, so every call would share one snapshot file"
[ "$FILE" = "${DIR}/${KEY}" ] \
  || fail "cc_snapshot_file is not cc_snapshot_dir + key:"$'\n'"file: $FILE"$'\n'"dir:  $DIR"$'\n'"key:  $KEY"

# 2. State, not cache (#63). A cache is discardable by definition and losing a
#    snapshot loses a capture, so the store must not migrate under XDG_CACHE_HOME
#    just to match keeper-state.sh's directory convention.
case "$DIR" in
  "$TMP/state"/*) : ;;
  *) fail "cc_snapshot_dir ignored XDG_STATE_HOME; got: $DIR" ;;
esac
XDG_CACHE_HOME="$TMP/cache" DIR2="$(cc_snapshot_dir)"
case "$DIR2" in
  *"$TMP/cache"*) fail "cc_snapshot_dir resolved under XDG_CACHE_HOME: $DIR2" ;;
esac

# 3. Both hooks go through the accessor. The pre-hook writes the snapshot and the
#    post-hook reads and deletes it, so a hook that assembles the path itself can
#    be half-updated: the pre-hook keeps writing where the post-hook no longer
#    looks, every commit goes uncaptured, and both halves report success.
for h in scripts/commit-capture-pre.sh scripts/commit-capture.sh; do
  if grep -q 'pre-commit-head' "$ROOT_DIR/$h"; then
    fail "$h composes the snapshot path itself (found a literal 'pre-commit-head'); call cc_snapshot_dir/cc_snapshot_file instead:"$'\n'"$(grep -n 'pre-commit-head' "$ROOT_DIR/$h")"
  fi
  grep -q 'cc_snapshot_file' "$ROOT_DIR/$h" \
    || fail "$h does not call cc_snapshot_file, so it is not reading the shared layout"
done

# 4. Two concurrent commits in one session get two snapshots. The key is the
#    invocation, which is why this store cannot adopt keeper_vault_id — a
#    per-vault id would collapse both calls onto one file and the second commit
#    would consume the first's snapshot.
OTHER='{"tool_name":"Bash","tool_use_id":"toolu_state_2","session_id":"s-1","tool_input":{"command":"git commit -m y","cwd":"/tmp"}}'
[ "$(cc_snapshot_file "$OTHER")" != "$FILE" ] \
  || fail "two invocations in one session resolved to the same snapshot file"

# 5. No tool_use_id falls back to the session, and two sessions still differ.
S1='{"tool_name":"Bash","session_id":"sess-a","tool_input":{"command":"git commit -m x","cwd":"/tmp"}}'
S2='{"tool_name":"Bash","session_id":"sess-b","tool_input":{"command":"git commit -m x","cwd":"/tmp"}}'
[ -n "$(cc_snapshot_key "$S1")" ] || fail "a payload with no tool_use_id produced an empty key"
[ "$(cc_snapshot_file "$S1")" != "$(cc_snapshot_file "$S2")" ] \
  || fail "two sessions collapsed onto one snapshot file"

echo "PASS: commit-capture-state-store"
