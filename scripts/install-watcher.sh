#!/usr/bin/env bash
# install-watcher.sh — render or install the namespaced vaultkeeper scheduler.
# launchd on macOS, cron on Linux. Label/marker: com.nhangen.obsidian-vaultkeeper
# (documented in README so a host scheduler audit surfaces it).
set -euo pipefail
LABEL="com.nhangen.obsidian-vaultkeeper"

usage() { echo "usage: install-watcher.sh {label|render-launchd|render-cron|install} <tick_abs_path> [interval_secs]" >&2; exit 2; }

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
</dict>
</plist>
EOF
}

render_cron() {
  local tick="$1" interval="$2" minutes
  minutes=$(( interval / 60 )); [ "$minutes" -lt 1 ] && minutes=1
  printf '*/%s * * * * /bin/bash "%s" >/dev/null 2>&1 # %s\n' "$minutes" "$tick" "$LABEL"
}

install_watcher() {
  local tick="$1" interval="${2:-900}"
  case "$(uname -s)" in
    Darwin)
      local plist="$HOME/Library/LaunchAgents/${LABEL}.plist"
      render_launchd "$tick" "$interval" > "$plist"
      launchctl unload "$plist" 2>/dev/null || true
      launchctl load "$plist"
      echo "installed launchd agent: $plist" ;;
    *)
      local line; line="$(render_cron "$tick" "$interval")"
      ( crontab -l 2>/dev/null | grep -vF "# ${LABEL}"; printf '%s\n' "$line" ) | crontab -
      echo "installed cron line for ${LABEL}" ;;
  esac
}

case "${1:-}" in
  label)          printf '%s\n' "$LABEL" ;;
  render-launchd) [ $# -ge 3 ] || usage; render_launchd "$2" "$3" ;;
  render-cron)    [ $# -ge 3 ] || usage; render_cron "$2" "$3" ;;
  install)        [ $# -ge 2 ] || usage; install_watcher "$2" "${3:-900}" ;;
  *)              usage ;;
esac
