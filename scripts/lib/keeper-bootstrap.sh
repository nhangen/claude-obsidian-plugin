#!/usr/bin/env bash
# keeper-bootstrap.sh — self-activation for the vaultkeeper watcher.
#
# Sourced by the Stop hook (session-save.sh), which fires at the end of every
# session on whichever host you are working on. When that host has no
# vaultkeeper scheduler yet, keeper_ensure_active seeds the frontmatter schema,
# writes default keeper config, and installs the namespaced scheduler — once.
# Once the scheduler exists it runs the keeper autonomously, so every later
# call here is a cheap no-op. Non-interactive and never aborts its caller: a
# Stop hook cannot prompt, and activation must never break session-save.
#
# Per-host by necessity: Syncthing carries the vault, not a launchd plist or
# crontab line, so each host installs its own scheduler the first time normal
# workflow runs on it. Opt out with `keeper_autostart: false` in the config.

# Captured at source time — see the note in allowlist-validate.sh: zsh has no
# BASH_SOURCE, and its `$0` only names the sourced file while it is being read.
_kb_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# Returns non-zero rather than printing an empty path. The old `cd ../ && pwd`
# propagated its failure; a bare parameter strip cannot, and both callers use the
# result unchecked to build `bash "$scripts/..."` command lines. Testing for the
# sibling covers a `cd` that failed (empty) and one that succeeded onto the
# caller's cwd; it also covers `${x%/*}` having no root case, where "/" strips to "".
_kb_scripts() {
  local d="${_kb_lib_dir%/*}"
  [ -n "$d" ] && [ -f "$d/install-watcher.sh" ] || return 1
  printf '%s\n' "$d"
}

# Single source of truth for the namespace label: install-watcher.sh owns it.
# Deliberately does NOT swallow the installer's stderr — that text is the only
# thing separating a syntax error from a missing dependency. Redirecting is each
# caller's decision: keeper_ensure_active captures it to quote in its refusal,
# keeper_scheduler_installed drops it because a predicate has no channel to
# report on. The unchecked `$(_kb_scripts)` it used to interpolate turned a lost
# scripts dir into `bash /install-watcher.sh`; fail instead of the wrong path.
keeper_label() {
  local scripts
  scripts="$(_kb_scripts)" || return 1
  bash "$scripts/install-watcher.sh" label
}

keeper_scheduler_installed() {
  local os="${KEEPER_OS:-$(uname -s)}" label
  # A predicate has no channel to explain a fault on, so it must not leak the
  # installer's exit status — that status became this assignment's, and an errexit
  # caller died here, before the handler on the next line could turn it into a
  # plain "not installed". Nor its stderr, which would land unprefixed on whoever
  # asked. keeper_ensure_active is the caller that quotes the installer.
  label="$(keeper_label 2>/dev/null)" || label=""
  [ -n "$label" ] || return 1
  # Check LIVE state, not an on-disk artifact: install-watcher writes the plist
  # before `launchctl load`, so a failed load can leave a plist that was never
  # loaded. Reading `launchctl list` (mirroring the Linux `crontab -l` branch)
  # means a not-running agent is correctly seen as absent and retried.
  # Match the label as a whole field, not a substring: `launchctl list` puts
  # the label in the last column, and the cron marker ends the line. Anchoring
  # avoids a longer label that merely contains this one (anchored-identifier).
  case "$os" in
    Darwin) launchctl list 2>/dev/null | awk -v l="$label" '$NF==l{f=1} END{exit !f}' ;;
    *)      crontab -l 2>/dev/null | grep -q -- "# ${label}\$" ;;
  esac
}

# Append "key: value" after the opening --- if the key is absent. bash 3.2 safe.
_kb_cfg_ensure() {
  local key="$1" val="$2" cfg="$3" tmp
  grep -q "^${key}:" "$cfg" && return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/kbcfg-XXXXXX")" || return 1
  awk -v line="${key}: ${val}" '
    NR==1 && $0=="---" { print; print line; inserted=1; next }
    { print }
    END { if (!inserted) print line }
  ' "$cfg" > "$tmp" && mv "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
}

# keeper_ensure_active <config_file> <vault_path> [interval_secs]
keeper_ensure_active() {
  local cfg="$1" vault="$2" interval="${3:-900}"
  [ -f "$cfg" ] && [ -d "$vault" ] || return 0

  # `|| autostart=""` because a config without the key makes grep exit 1, and with
  # `pipefail` that becomes the assignment's status — errexit would abort the
  # sourcing hook here, on the ordinary first-run config. Absent means "not false".
  local autostart
  autostart="$(grep '^keeper_autostart:' "$cfg" | head -1 | sed 's/^keeper_autostart:[[:space:]]*//')" || autostart=""
  [ "$autostart" = "false" ] && return 0

  # Resolve the scripts dir before the label, so a lib that cannot find its own
  # siblings says that, instead of surfacing as "install-watcher.sh broken?" and
  # naming a file that is perfectly fine.
  local scripts
  if ! scripts="$(_kb_scripts)"; then
    printf 'vaultkeeper: cannot find the scripts dir beside this lib (looked beside "%s"); activation skipped\n' "$_kb_lib_dir" >&2
    return 0
  fi

  # A missing/empty label means the installer is broken — that's an error to
  # report, not a "not installed" signal to barrel past into a doomed install.
  # Capture the installer's own stderr so the refusal quotes the actual fault
  # instead of guessing; a failed mktemp costs only the quote, not the refusal.
  local label lblerr lbltmp
  lbltmp="$(mktemp "${TMPDIR:-/tmp}/kblbl-XXXXXX" 2>/dev/null)" || lbltmp=""
  # `|| label=""` is load-bearing, not defensive: a broken installer exits
  # non-zero, that status becomes the assignment's, and an errexit caller would
  # die right here — before the refusal below could print a word.
  if [ -n "$lbltmp" ]; then
    label="$(keeper_label 2>"$lbltmp")" || label=""
    lblerr="$(tr '\n' ' ' < "$lbltmp")" || lblerr=""
    rm -f "$lbltmp"
  else
    label="$(keeper_label 2>/dev/null)" || label=""
    lblerr=""
  fi
  if [ -z "$label" ]; then
    printf 'vaultkeeper: %s/install-watcher.sh did not report the scheduler label%s; skipping activation\n' \
      "$scripts" "${lblerr:+ — it said: ${lblerr% }}" >&2
    return 0
  fi

  keeper_scheduler_installed && return 0

  local tick="$scripts/vaultkeeper-tick.sh"
  if ! bash "$scripts/seed-frontmatter-schema.sh" "$vault" "$cfg" >/dev/null 2>&1; then
    printf 'vaultkeeper: frontmatter-schema seed failed; using default (tags type)\n' >&2
  fi
  # Non-fatal, but not silent: `|| true` discarded a failed mktemp/awk/mv, and a
  # config that never gains keeper_interval_secs then runs at the compiled-in
  # default forever with nothing to explain why. Name the key and the
  # consequence, the way the schema seed above names its fallback. `|| printf`
  # keeps the exit status 0, so the hook still cannot be aborted by this.
  _kb_cfg_ensure keeper_autostart true "$cfg" \
    || printf 'vaultkeeper: could not write keeper_autostart to %s; opt-out state is unrecorded\n' "$cfg" >&2
  _kb_cfg_ensure keeper_interval_secs "$interval" "$cfg" \
    || printf 'vaultkeeper: could not write keeper_interval_secs to %s; readers will fall back to the %ss default\n' "$cfg" "$interval" >&2

  local ok=""
  if [ -n "${VAULTKEEPER_INSTALL:-}" ]; then
    "$VAULTKEEPER_INSTALL" "$tick" "$interval" && ok=1
  else
    bash "$scripts/install-watcher.sh" install "$tick" "$interval" && ok=1
  fi
  if [ -n "$ok" ]; then
    printf 'vaultkeeper: activated watcher on this host (interval %ss)\n' "$interval" >&2
  else
    printf 'vaultkeeper: watcher install FAILED on this host (will retry next session); run manually: bash %s/install-watcher.sh install %s %s\n' "$scripts" "$tick" "$interval" >&2
  fi
  return 0
}
