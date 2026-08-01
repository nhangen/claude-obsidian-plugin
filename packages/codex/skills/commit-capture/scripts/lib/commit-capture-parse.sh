#!/usr/bin/env bash
# commit-capture-parse.sh
# Payload decoding, command inspection, and repo resolution shared by the
# commit-capture PreToolUse and PostToolUse hooks.
#
# The two hooks must agree, exactly, on three answers: does this command invoke
# `git commit`, which repository would it run in, and what key names the
# snapshot. When the pre-hook says "no" and the post-hook says "yes", the
# post-hook sees a missing snapshot and drops a real commit; when they disagree
# about the repo, the snapshot compares two different HEADs. Neither divergence
# is observable in either hook alone, so the answers live here and both source
# them rather than each carrying its own copy.

# The payload is JSON: a quote inside the command arrives as \" and a newline as
# the two characters \n. Truncating a value at the first `"` therefore cut the
# command short at its first quoted argument, silently dropping
# `cd "<worktree>" && git commit` — this project's own documented workflow — and
# `git add "a b.txt" && git commit`. Decode the string instead of slicing it.
# Walking the string a character at a time cost ~11s on a 4 KB command, which is
# not something a hook on every Bash call may spend. Substitute the two escapes
# that can be confused with the closing quote for placeholders, cut at the first
# quote that is now genuinely unescaped, then restore — all bulk expansions.
# \uXXXX is left as written: it can never be a delimiter or a shell separator.
cc_json_value() {
  local s="$1" key="$2"
  s="${s#*"$key"}"
  [ "$s" != "$1" ] || { printf '%s' ''; return 0; }
  s="${s#*\"}"
  s="${s//\\\\/$'\001'}"
  s="${s//\\\"/$'\002'}"
  s="${s%%\"*}"
  s="${s//\\n/$'\n'}"
  s="${s//\\t/$'\t'}"
  s="${s//\\r/$'\r'}"
  s="${s//$'\002'/\"}"
  s="${s//$'\001'/\\}"
  printf '%s' "$s"
}

# Pull the first shell token off a string, honouring "…" and '…' so a path with
# spaces survives. Sets CC_TOKEN and CC_REST.
CC_TOKEN=""
CC_REST=""
cc_take_token() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  case "$s" in
    '"'*) s="${s#\"}"; CC_TOKEN="${s%%\"*}"; CC_REST="${s#"$CC_TOKEN"}"; CC_REST="${CC_REST#\"}" ;;
    "'"*) s="${s#\'}"; CC_TOKEN="${s%%\'*}"; CC_REST="${s#"$CC_TOKEN"}"; CC_REST="${CC_REST#\'}" ;;
    *)    CC_TOKEN="${s%%[[:space:]]*}"; CC_REST="${s#"$CC_TOKEN"}" ;;
  esac
  CC_REST="${CC_REST#"${CC_REST%%[![:space:]]*}"}"
}

# Heredoc bodies are not commands. This only became reachable once newlines were
# decoded: `cat <<EOF` / `git commit -q` / `EOF` used to survive as one segment and
# be rejected, and now the body line would match the gate on its own. The opening
# line is kept, because `git commit -F - <<EOF` is a real invocation.
cc_strip_heredoc_bodies() {
  local s="$1" out="" line trimmed delim="" tag
  while IFS= read -r line; do
    if [ -n "$delim" ]; then
      trimmed="${line#"${line%%[![:space:]]*}"}"
      [ "$trimmed" = "$delim" ] && delim=""
      continue
    fi
    out="${out}${line}"$'\n'
    case "$line" in
      *'<<<'*) ;;                                   # herestring: no body follows
      *'<<'*)
        tag="${line#*<<}"
        tag="${tag#-}"
        tag="${tag#"${tag%%[![:space:]]*}"}"
        tag="${tag%%[[:space:]]*}"
        tag="${tag%%[;&|)]*}"
        tag="${tag//\"/}"
        tag="${tag//\'/}"
        [ -n "$tag" ] && delim="$tag"
        ;;
    esac
  done <<EOF
$s
EOF
  printf '%s' "$out"
}

# `git commit` must be an actual command word, not a substring. Matching the
# substring captured `grep -rn "git commit" docs/`, `echo "run git commit"`, and
# `git log --grep="git commit"` — each of which fires the hook on a Bash call
# that committed nothing.
# Split the command on shell separators and require some segment to *invoke* git
# with the `commit` subcommand. A newline is a separator too: it arrives decoded
# by now, and `git add -A` on one line with `git commit` on the next is the most
# common shape there is.
#
# Returns 0 when some segment invokes `git commit`, 1 otherwise. Sets
# CC_GIT_C_DIR and CC_CD_TARGET to where git would have run.
CC_GIT_C_DIR=""
CC_CD_TARGET=""
cc_invokes_commit() {
  local segments seg word args assign flag found=0
  CC_GIT_C_DIR=""
  CC_CD_TARGET=""
  segments="$(cc_strip_heredoc_bodies "$1")"
  segments="${segments//&&/$'\n'}"
  segments="${segments//||/$'\n'}"
  segments="${segments//;/$'\n'}"
  segments="${segments//|/$'\n'}"
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"          # ltrim
    # Shell keywords and grouping tokens sit in front of the real command word, so
    # `if true; then git commit; fi` and `for f in a; do git commit; done` used to
    # miss entirely.
    while :; do
      case "$seg" in
        'then '*|'do '*|'else '*|'elif '*|'time '*|'exec '*|'! '*|'{ '*)
          seg="${seg#* }" ;;
        '('*|'{'*) seg="${seg#?}" ;;
        *) break ;;
      esac
      seg="${seg#"${seg%%[![:space:]]*}"}"
    done
    # Leading VAR=value assignments (GIT_AUTHOR_DATE=… git commit …).
    while :; do
      case "$seg" in
        [A-Za-z_]*=*)
          assign="${seg%%=*}"
          case "$assign" in
            *[!A-Za-z0-9_]*) break ;;
          esac
          case "$seg" in
            *' '*) seg="${seg#* }"; seg="${seg#"${seg%%[![:space:]]*}"}" ;;
            *) break ;;
          esac
          ;;
        *) break ;;
      esac
    done
    cc_take_token "$seg"
    word="$CC_TOKEN"
    args="$CC_REST"
    # A wrapper can sit in front of git. RTK's own PreToolUse hook returns
    # `updatedInput` from `rtk rewrite`, so the command the PostToolUse payload
    # reports is `rtk git commit` while the pre-hook's payload still said
    # `git commit` — the two halves of the gate then disagreed about whether a
    # commit happened and the capture died silently. Allowlisted by name: skipping
    # any unrecognized leading word would make `rtk echo git commit` a commit.
    if [ "${word##*/}" = rtk ] && [ -n "$args" ]; then
      cc_take_token "$args"
      word="$CC_TOKEN"
      args="$CC_REST"
      if [ "${word##*/}" = proxy ] && [ -n "$args" ]; then
        cc_take_token "$args"
        word="$CC_TOKEN"
        args="$CC_REST"
      fi
    fi
    # Match the basename so /usr/bin/git counts, and remember a `cd` target: it is
    # where git actually ran.
    case "${word##*/}" in
      cd)
        while :; do
          case "$args" in
            -*) cc_take_token "$args"; args="$CC_REST" ;;
            *) break ;;
          esac
        done
        cc_take_token "$args"
        [ -n "$CC_TOKEN" ] && [ -z "$CC_CD_TARGET" ] && CC_CD_TARGET="$CC_TOKEN"
        continue
        ;;
      git) ;;
      *) continue ;;
    esac
    [ -n "$args" ] || continue
    # Skip git's global flags. `-C <dir>` is recorded, not just skipped: the gate
    # used to parse it while resolution ignored it, so the two layers disagreed
    # about which repository the commit landed in.
    while :; do
      case "$args" in
        -C' '*|-c' '*|--git-dir' '*|--work-tree' '*|--namespace' '*|--exec-path' '*)
          flag="${args%%[[:space:]]*}"
          args="${args#"$flag"}"
          args="${args#"${args%%[![:space:]]*}"}"
          cc_take_token "$args"
          [ "$flag" = "-C" ] && [ -z "$CC_GIT_C_DIR" ] && CC_GIT_C_DIR="$CC_TOKEN"
          args="$CC_REST"
          ;;
        -*) cc_take_token "$args"; args="$CC_REST" ;;
        *) break ;;
      esac
      [ -n "$args" ] || break
    done
    case "$args" in
      commit|commit' '*|commit$'\t'*) found=1; break ;;
    esac
  done <<EOF
$segments
EOF
  [ "$found" -eq 1 ]
}

# A relative `cd` has to be resolved against the payload's cwd, not the hook's:
# with a same-named directory beside the hook it captured a different
# repository's commit outright, and filed the note under that repo's name.
cc_resolve_repo_dir() {
  local d="$1" payload_cwd="$2"
  [ -n "$d" ] || return 1
  case "$d" in
    '~') d="$HOME" ;;
    '~/'*) d="$HOME/${d#\~/}" ;;
  esac
  case "$d" in
    /*) ;;
    *)
      [ -n "$payload_cwd" ] || return 1
      d="$payload_cwd/$d"
      ;;
  esac
  [ -d "$d" ] || return 1
  git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  printf '%s' "$d"
}

# Which repo? The commit may have been made in a worktree via
# `cd <worktree> && git commit`, which is this project's documented workflow.
# Running git in the hook's own cwd read the wrong HEAD — dropping the capture
# when the session repo was idle, or capturing the wrong commit when it wasn't.
# Prints the repo dir, or returns 1 when no candidate is a git repository.
#
# CALL ORDER: `cc_invokes_commit` must run first. It is what sets CC_GIT_C_DIR and
# CC_CD_TARGET, the two highest-priority candidates read below; calling this alone
# silently degrades to the payload cwd, which is a different repository whenever the
# command changed directory.
cc_find_repo_dir() {
  local payload_cwd="$1" cand resolved
  for cand in "$CC_GIT_C_DIR" "$CC_CD_TARGET" "$payload_cwd" "$PWD"; do
    [ -n "$cand" ] || continue
    resolved="$(cc_resolve_repo_dir "$cand" "$payload_cwd")" || continue
    printf '%s' "$resolved"
    return 0
  done
  return 1
}

cc_state_dir() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/claude-obsidian"
}

# Anything either hook says reaches Claude only as hookSpecificOutput.additionalContext:
# bare stdout on exit 0 goes to the debug log for both PreToolUse and PostToolUse, and
# the only alternatives — exit 2, or a permissionDecision — block or error the very
# commit we are trying to observe. Shared here so the two hooks cannot drift on either
# the envelope or the escaping.
#
# The escaping is not decorative: a commit subject reaches this, and an unparseable
# envelope loses the whole message rather than the subject.
cc_json_escape() {
  local s="$1"
  # Backslashes first, or the escapes added below get doubled.
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  # No raw control byte is legal in a JSON string, and nothing above covers them.
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037\177'
}

# $1 = hook event name, $2 = text. Emits nothing for empty text so a caller can
# flush unconditionally.
cc_deliver_context() {
  local event="$1" text="$2"
  [ -n "$text" ] || return 0
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' \
    "$event" "$(cc_json_escape "$text")"
}

# Keyed on a bounded digest rather than a slug of the raw value: slugging split
# one repo across several keys and, in a deep worktree, exceeded NAME_MAX.
# The fallback keeps the value's own bytes (filtered to a filename-safe set, then
# truncated) rather than a constant — a constant would quietly collapse every
# invocation onto one key, which is the crossing failure the digest prevents.
cc_digest() {
  local d
  d=$(printf '%s' "$1" | cksum 2>/dev/null | tr -cd '0-9') || d=""
  if [ -z "$d" ]; then
    d=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_-')
    d="nocksum-${d:0:64}"
  fi
  printf '%s' "$d"
}

# Snapshot key. A Bash call carries a tool_use_id, which names *this* invocation
# and so survives two commits running concurrently in one session. When the
# payload has no such field, fall back to the session — the pair still lines up
# for the one-at-a-time case, and the snapshot records its repo root so the
# post-hook can tell when it got somebody else's.
# Both are reduced to a bounded, filename-safe digest: an id with a `/` in it
# would write outside the directory, and a long one exceeds NAME_MAX, where the
# open fails and the whole gate silently stops working.
cc_snapshot_key() {
  local payload="$1" id
  id="$(cc_json_value "$payload" '"tool_use_id"')"
  [ -n "$id" ] || id="session:$(cc_json_value "$payload" '"session_id"')"
  cc_digest "$id"
}

# Where a snapshot lives. The pre-hook writes it and the post-hook reads and
# deletes it, so the two halves must agree byte for byte on the path — and they
# each used to assemble it themselves from cc_state_dir + a literal
# `pre-commit-head` + cc_snapshot_key. Two copies of a layout is a layout that
# can be half-changed: the pre-hook would keep writing snapshots the post-hook
# no longer looks for, and the symptom is every commit going uncaptured with
# both halves reporting success. One accessor, called by both.
cc_snapshot_dir() {
  printf '%s/pre-commit-head' "$(cc_state_dir)"
}

cc_snapshot_file() {
  printf '%s/%s' "$(cc_snapshot_dir)" "$(cc_snapshot_key "$1")"
}

# Deliberately NOT keeper-state.sh's shape (#63), and the differences are the
# reason rather than drift:
#
#   - XDG_STATE_HOME, not XDG_CACHE_HOME. A cache is defined as discardable;
#     losing a snapshot loses a capture, which is the failure the gate exists to
#     prevent. State is what this is.
#   - Keyed by invocation, not by a hashed vault id. keeper_vault_id answers
#     "which vault's index is this" for a durable per-vault snapshot. These
#     records are per-Bash-call and live for the length of one tool call, so the
#     tool_use_id is the only key that keeps two concurrent commits apart — a
#     vault id would collapse them onto one file.
#   - No keeper_state_init: the pre-hook must mkdir and report failure itself,
#     because it is the half that can still warn before the commit runs.
#
# What it does take from keeper-state.sh is the write discipline — tmp file plus
# rename, never truncate-in-place — implemented at the pre-hook's write site
# where the failure can be reported.

# cc_org_repo <remote> <repo_name_fallback>
#
# Echoes the `org_repo` value for a remote URL. Extracted from the PostToolUse
# hook so that the harness integrations (Cursor, Codex) can reach it instead of
# re-deriving it in prose — every previous copy of this logic omitted the
# userinfo strip below, which is how a token-bearing remote ends up in a synced
# note's `repo:` frontmatter. scripts/commit-detect.sh was deleted for being a
# second implementation; this is the opposite move, one implementation with two
# callers.
cc_org_repo() {
  local REMOTE="$1" REPO_NAME="${2:-unknown}"
  local ORG_REPO REMOTE_PATH HOSTPART REST AFTER_COLON ORG_LEAF ORG_GROUPS

  # Host-agnostic, and userinfo is stripped before splitting. The old version
  # matched SSH and github.com only, so an HTTPS GitLab remote fell through to
  # local/<repo> — one repo recorded under three org_repo values, hence three
  # capture folders. Stripping userinfo is not cosmetic: a remote carrying a token
  # (https://oauth2:TOKEN@host:8443/org/repo.git) matched the SSH arm and the token
  # survived into org_repo, which is printed and written into a note's `repo:`
  # frontmatter, then synced. See no-secrets-in-logs.
  ORG_REPO=""
  REMOTE_PATH="$REMOTE"
  case "$REMOTE_PATH" in
    *://*) REMOTE_PATH="${REMOTE_PATH#*://}" ;;
  esac
  # Drop userinfo (anything before an @ that precedes the first /).
  case "$REMOTE_PATH" in
    *@*)
      HOSTPART="${REMOTE_PATH%%/*}"
      case "$HOSTPART" in
        *@*) REMOTE_PATH="${HOSTPART##*@}${REMOTE_PATH#"$HOSTPART"}" ;;
      esac
      ;;
  esac
  # A colon is either an scp-style host:path separator or a port. Decide by what
  # follows it: all digits means port (drop it), anything else means path.
  HOSTPART="${REMOTE_PATH%%/*}"
  REST=""
  case "$REMOTE_PATH" in
    */*) REST="${REMOTE_PATH#*/}" ;;
  esac
  case "$HOSTPART" in
    *:*)
      AFTER_COLON="${HOSTPART##*:}"
      case "$AFTER_COLON" in
        ''|*[!0-9]*) ORG_REPO="${AFTER_COLON}${REST:+/$REST}" ;;
        *)           ORG_REPO="$REST" ;;
      esac
      ;;
    *) ORG_REPO="$REST" ;;
  esac
  ORG_REPO="${ORG_REPO#/}"
  while :; do
    case "$ORG_REPO" in
      */) ORG_REPO="${ORG_REPO%/}" ;;
      *)  break ;;
    esac
  done
  ORG_REPO="${ORG_REPO%.git}"
  case "$ORG_REPO" in
    ''|*/|*/*) : ;;
    *) ORG_REPO="" ;;                       # single segment is not org/repo
  esac
  case "$REMOTE" in
    ''|local) ORG_REPO="" ;;
    /*|./*|../*) ORG_REPO="" ;;             # bare local path
    file://*) ORG_REPO="" ;;
  esac
  # org_repo becomes a directory under the vault, so it must not escape it. A
  # remote of https://host/../../../../tmp/pwned.git derived cleanly into
  # `../../../../tmp/pwned`, with nothing downstream to catch it.
  case "$ORG_REPO" in
    /*|*..*) ORG_REPO="" ;;
  esac
  case "$ORG_REPO" in
    ''|*/) ORG_REPO="local/$REPO_NAME" ;;
  esac
  # GitLab subgroups nest arbitrarily deep, so `https://gitlab.com/g/sub1/sub2/repo`
  # derived `g/sub1/sub2/repo` and the note landed four levels under
  # Projects/Development/ where every other repo lands two. The prefix-shaped
  # routing overrides in the capture rule do not anticipate that, and neither does
  # anything that globs `Projects/Development/*/*`.
  #
  # org_repo is always exactly two segments now: everything above the repository is
  # folded into the first, joined with `-`. Collapsing to `<top-group>/<repo>`
  # instead — the other option the issue offered — would make `g/team-a/api` and
  # `g/team-b/api` the same folder, so two repos' notes would interleave in one
  # file. Keeping the repository as the leaf also means `repo_name` below, which
  # reads the last segment, needs no special case.
  case "$ORG_REPO" in
    */*/*)
      ORG_LEAF="${ORG_REPO##*/}"
      ORG_GROUPS="${ORG_REPO%/*}"
      ORG_REPO="$(printf '%s' "$ORG_GROUPS" | tr '/' '-')/${ORG_LEAF}"
      ;;
  esac
  printf '%s' "$ORG_REPO"
}
