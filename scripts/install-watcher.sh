#!/usr/bin/env bash
# install-watcher.sh — render or install the namespaced vaultkeeper scheduler.
# launchd on macOS, cron on Linux. Label/marker: com.nhangen.obsidian-vaultkeeper
# (documented in README so a host scheduler audit surfaces it).
set -euo pipefail
LABEL="com.nhangen.obsidian-vaultkeeper"

usage() { echo "usage: install-watcher.sh {label|installed-program|state|render-launchd|render-cron|install} <tick_abs_path> [interval_secs]" >&2; exit 2; }

# Did WE render what is installed? The discriminator is the program's basename, not
# its full path (#44).
#
# A full-path comparison cannot work: our own path is version-pinned into the plugin
# cache, so it legitimately changes on every plugin update, and refusing on any
# difference would block the re-install that heals a stranded pinned path (#35) — the
# very failure the delegator exists to avoid. Every path we render ends in
# `vaultkeeper-tick.sh`; a hand-written wrapper (the live host's
# `~/.claude/hooks/obsidian-vaultkeeper-tick.sh`, which resolves the newest versioned
# dir with `sort -V`) does not. So: same basename → ours, replace it; anything else →
# somebody configured this on purpose, and silently replacing it swapped a
# version-resilient wrapper for a pinned path while printing "activated".
_TICK_BASENAME="vaultkeeper-tick.sh"

_program_of() {
  # First <string> inside ProgramArguments that is not the interpreter.
  sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$1" 2>/dev/null \
    | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' \
    | grep -v '^/bin/bash$' \
    | head -1
}

_own_program() {
  local plist="$1" prog
  # Nothing there yet is ours to write.
  [ -f "$plist" ] || return 0
  prog="$(_program_of "$plist")"
  # An unparseable or program-less plist is not something to guess about either.
  [ -n "$prog" ] || return 1
  [ "${prog##*/}" = "$_TICK_BASENAME" ]
}

_own_cron_line() {
  case "$1" in
    *"/$_TICK_BASENAME"*) return 0 ;;
    *) return 1 ;;
  esac
}

render_launchd() {
  local tick="$1" interval="$2"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${tick}</string>
  </array>
  <key>StartInterval</key><integer>${interval}</integer>
  <key>RunAtLoad</key><true/>
  <!-- Logs, because the tick's own stderr is the only account of a fault on a
       host nobody is watching: the 700+ ticks that logged "Too many open files"
       above "scan complete" (#42) were diagnosed from exactly these two paths on
       a hand-written plist, and a rendered one had no such record. -->
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/${LABEL}.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/${LABEL}.log</string>
</dict>
</plist>
EOF
}

render_cron() {
  local tick="$1" interval="$2" minutes
  minutes=$(( interval / 60 )); [ "$minutes" -lt 1 ] && minutes=1
  printf '*/%s * * * * /bin/bash "%s" >/dev/null 2>&1 # %s\n' "$minutes" "$tick" "$LABEL"
}

installed_program() {
  local prog=""
  case "$(uname -s)" in
    Darwin)
      prog="$(_program_of "$HOME/Library/LaunchAgents/${LABEL}.plist")"
      ;;
    *)
      # The tick path is the double-quoted field of the rendered cron line.
      prog="$(crontab -l 2>/dev/null | grep -F "# ${LABEL}" | head -1 \
        | sed -n 's/.*"\([^"]*\)".*/\1/p')"
      ;;
  esac
  [ -n "$prog" ] || return 1
  printf '%s\n' "$prog"
}

install_watcher() {
  local tick="$1" interval="${2:-900}"
  case "$(uname -s)" in
    Darwin)
      local plist="$HOME/Library/LaunchAgents/${LABEL}.plist"
      if ! _own_program "$plist"; then
        echo "install-watcher: $plist runs $(_program_of "$plist"), which this script did not render — refusing to replace it" >&2
        echo "install-watcher: that is usually a deliberate wrapper (a delegator that resolves the newest plugin version, per #35). Remove or update the plist by hand if you want it rebuilt." >&2
        exit 1
      fi
      mkdir -p "$HOME/Library/Logs"
      render_launchd "$tick" "$interval" > "$plist"
      launchctl unload "$plist" 2>/dev/null || true
      if ! launchctl load "$plist"; then
        rm -f "$plist"
        echo "install-watcher: launchctl load failed; removed $plist (no unloaded artifact left behind)" >&2
        exit 1
      fi
      echo "installed launchd agent: $plist" ;;
    *)
      local existing
      existing="$(crontab -l 2>/dev/null | grep -F "# ${LABEL}" | head -1)" || existing=""
      if [ -n "$existing" ] && ! _own_cron_line "$existing"; then
        echo "install-watcher: the existing ${LABEL} crontab line runs something this script did not render — refusing to replace it" >&2
        echo "install-watcher: [$existing]" >&2
        exit 1
      fi
      local line; line="$(render_cron "$tick" "$interval")"
      ( crontab -l 2>/dev/null | grep -vF "# ${LABEL}"; printf '%s\n' "$line" ) | crontab -
      echo "installed cron line for ${LABEL}" ;;
  esac
}

case "${1:-}" in
  label)          printf '%s\n' "$LABEL" ;;
  # What program is the installed entry actually pointing at? Prints nothing and
  # exits 1 when there is no entry. Lives here, beside `label`, so plist and cron
  # layout stay in one file — keeper-bootstrap reads this rather than parsing XML
  # itself (#35).
  installed-program) installed_program ;;
  # label + installed program in ONE invocation. keeper_ensure_active needs both, and
  # an installed host is meant to cost exactly one installer spawn per session — the
  # thing the label/predicate split already went to trouble to keep at one.
  state)          printf '%s\t%s\n' "$LABEL" "$(installed_program || true)" ;;
  render-launchd) [ $# -ge 3 ] || usage; render_launchd "$2" "$3" ;;
  render-cron)    [ $# -ge 3 ] || usage; render_cron "$2" "$3" ;;
  install)        [ $# -ge 2 ] || usage; install_watcher "$2" "${3:-900}" ;;
  *)              usage ;;
esac
