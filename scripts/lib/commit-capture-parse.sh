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
