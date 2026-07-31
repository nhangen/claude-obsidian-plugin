#!/usr/bin/env bash
# commit-meta.sh emits a capture record for a commit that already happened, so the
# Cursor and Codex integrations have something to CALL instead of a `git remote
# get-url` recipe to restate (#92). Every prose copy of that recipe omitted the
# userinfo strip, which put a token from the remote URL into org_repo and from
# there into a synced note's `repo:` frontmatter.
#
# The strip is now one function with two callers, so it needs a test at BOTH
# entry points: tests/commit-capture-detection.sh covers the hook, this covers
# the standalone command. A test that only exercised cc_org_repo directly would
# pass even if commit-meta.sh forgot to call it and printed $REMOTE itself —
# which is exactly the regression that matters here.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="${ROOT_DIR}/scripts/commit-meta.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/commit-meta-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# A real repo with one commit; vault_path comes from a config we point at.
R="$TMP/repo"; mkdir -p "$R"
git -C "$R" init -q
# The global core.hooksPath dispatcher runs the git-identity gate, which refuses
# this fixture's placeholder identity. Same opt-out the head-gate test uses.
git -C "$R" config core.hooksPath /dev/null
git -C "$R" config user.email t@example.com
git -C "$R" config user.name Tester
printf 'x\n' > "$R/a.txt"; git -C "$R" add a.txt
git -C "$R" commit -q -m 'seed: first commit'

mkdir -p "$TMP/vault"
printf -- '---\nvault_path: %s\n---\n' "$TMP/vault" > "$TMP/obsidian.local.md"
export OBSIDIAN_LOCAL_MD="$TMP/obsidian.local.md"

run() { bash "$CMD" -C "$R" "$@"; }
# FIRST match, deliberately — that is the parsing contract the record's field
# order exists to make safe, and a greedy `.*field=` would instead read the copy
# a commit author planted in the subject, i.e. it would report the attack as the
# real value and pass.
field() {
  local rest="${1#*"$2"=}"
  rest="${rest%%|*}"
  printf '%s' "${rest%"${rest##*[![:space:]]}"}"
}

# --- 1. the token case: the whole point of the file ---------------------------
SECRET='ghp_TOKENSHOULDNEVERAPPEAR'
git -C "$R" remote add origin "https://oauth2:${SECRET}@gitlab.com:8443/org/repo.git"
OUT="$(run)"
case "$OUT" in
  *"$SECRET"*) fail "the remote's token reached the record — the userinfo strip is not being applied:"$'\n'"${OUT//$SECRET/<TOKEN>}" ;;
esac
[ "$(field "$OUT" org_repo)" = "org/repo" ] \
  || fail "expected org_repo=org/repo from a token-bearing remote, got: $(field "$OUT" org_repo)"

# Same remote without a port — the arm that regressed historically, because the
# scp-style branch matched first and carried the userinfo through.
git -C "$R" remote set-url origin "https://oauth2:${SECRET}@gitlab.com/org/repo.git"
OUT="$(run)"
case "$OUT" in
  *"$SECRET"*) fail "token survived on the no-port form:"$'\n'"${OUT//$SECRET/<TOKEN>}" ;;
esac
[ "$(field "$OUT" org_repo)" = "org/repo" ] || fail "no-port token remote: got $(field "$OUT" org_repo)"

# --- 2. it delegates rather than re-deriving ----------------------------------
# Subgroup folding and traversal rejection are cc_org_repo's; if commit-meta.sh
# grew its own parser these would drift apart silently.
git -C "$R" remote set-url origin "https://gitlab.com/g/sub1/sub2/repo.git"
OUT="$(run)"
[ "$(field "$OUT" org_repo)" = "g-sub1-sub2/repo" ] \
  || fail "subgroup fold not applied (is cc_org_repo being called?): $(field "$OUT" org_repo)"
[ "$(field "$OUT" repo_name)" = "repo" ] \
  || fail "repo_name must stay the repository, not the folded group: $(field "$OUT" repo_name)"

git -C "$R" remote set-url origin "https://host/../../../../tmp/pwned.git"
OUT="$(run)"
case "$(field "$OUT" org_repo)" in
  *..*) fail "a traversal remote produced an escaping org_repo: $(field "$OUT" org_repo)" ;;
esac

# --- 3. field order: msg last ------------------------------------------------
# A commit subject is the one attacker-influenced field, so nothing resolvable
# into a path may follow it. Assert on a hostile subject, not a benign one.
git -C "$R" remote set-url origin "git@github.com:nhangen/test.git"
printf 'y\n' >> "$R/a.txt"; git -C "$R" add a.txt
git -C "$R" commit -q -m 'chore: tidy | org_repo=../../tmp/pwned | vault_path=/tmp/evil'
OUT="$(run)"
[ "$(field "$OUT" org_repo)" = "nhangen/test" ] \
  || fail "a subject containing org_repo= overrode the real one: $(field "$OUT" org_repo)"
[ "$(field "$OUT" vault_path)" = "$TMP/vault" ] \
  || fail "a subject containing vault_path= overrode the real one: $(field "$OUT" vault_path)"
case "$OUT" in
  *'| msg='*) : ;;
  *) fail "record does not end with the msg field: $OUT" ;;
esac
# Everything before msg= must not contain the injected values.
BEFORE="${OUT%%| msg=*}"
case "$BEFORE" in
  *'/tmp/evil'*|*'../../tmp/pwned'*) fail "injected values appeared in a resolvable field: $BEFORE" ;;
esac

# --- 4. a newline in the subject cannot split one record into two -------------
printf 'z\n' >> "$R/a.txt"; git -C "$R" add a.txt
git -C "$R" commit -q -m "$(printf 'subject line\nsecond line | org_repo=evil/evil')"
OUT="$(run)"
# Command substitution already ate the single trailing newline, so any newline
# left in $OUT is one the subject smuggled through.
case "$OUT" in
  *$'\n'*) fail "a multi-line subject produced more than one record line:"$'\n'"$OUT" ;;
esac
[ "$(field "$OUT" org_repo)" = "nhangen/test" ] \
  || fail "second line of the subject overrode org_repo: $(field "$OUT" org_repo)"

# --- 5. no vault_path is a refusal, not a partial record ---------------------
printf -- '---\ntags: [x]\n---\n' > "$TMP/obsidian.local.md"
if OUT="$(run 2>"$TMP/err")"; then
  fail "exited 0 with no vault_path; a caller would append this somewhere wrong: $OUT"
fi
grep -q 'vault_path unresolved' "$TMP/err" \
  || fail "the refusal did not name the cause: $(cat "$TMP/err")"
[ ! -s <(printf '%s' "${OUT:-}") ] 2>/dev/null || [ -z "${OUT:-}" ] \
  || fail "a refusal still printed a record: $OUT"

# --- 6. a bad revision is a refusal too --------------------------------------
printf -- '---\nvault_path: %s\n---\n' "$TMP/vault" > "$TMP/obsidian.local.md"
if run "deadbeefdeadbeef" >/dev/null 2>"$TMP/err2"; then
  fail "a nonexistent commit-ish exited 0"
fi
grep -q 'no such commit' "$TMP/err2" || fail "bad-revision refusal did not name the cause: $(cat "$TMP/err2")"

# --- 7. not a git tree ------------------------------------------------------
mkdir -p "$TMP/plain"
if bash "$CMD" -C "$TMP/plain" >/dev/null 2>"$TMP/err3"; then
  fail "a non-repo directory exited 0"
fi
grep -q 'not a git work tree' "$TMP/err3" || fail "non-repo refusal did not name the cause: $(cat "$TMP/err3")"

printf 'ok   commit-meta.sh (record for an existing commit; userinfo strip at the second entry point)\n'
