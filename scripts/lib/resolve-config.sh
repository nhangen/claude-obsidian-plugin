#!/usr/bin/env bash
# resolve-config.sh — locate obsidian.local.md in a version-independent way.
#
# The plugin is installed under a version-pinned cache dir
# (~/.claude/plugins/cache/<owner>/obsidian/<version>/), which is replaced on
# every update. A config written next to the scripts therefore disappears on
# upgrade. To avoid ever re-pointing config by hand, readers resolve it from a
# stable, version-independent location first and fall back to the plugin dir
# only as a legacy default.
#
# Usage:
#   . "$(dirname "$0")/lib/resolve-config.sh"
#   CONFIG_FILE="$(resolve_obsidian_config "${PLUGIN_ROOT:-}")" || CONFIG_FILE=""
#
# Resolution order (first existing file wins):
#   1. $OBSIDIAN_LOCAL_MD                                  (explicit override)
#   2. ${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md (stable home)
#   3. <plugin_root>/obsidian.local.md                     (legacy fallback)

# Canonical stable path — also where setup should write. Echoes the path
# (whether or not it exists) so the setup wizard can target it.
obsidian_config_stable_path() {
  printf '%s/claude-obsidian/obsidian.local.md\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

resolve_obsidian_config() {
  local plugin_root="${1:-${CLAUDE_PLUGIN_ROOT:-}}"
  local candidates=(
    "${OBSIDIAN_LOCAL_MD:-}"
    "$(obsidian_config_stable_path)"
    "${plugin_root:+${plugin_root%/}/obsidian.local.md}"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -n "$c" ] && [ -f "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# CLI mode: when executed directly (not sourced), print the resolved config
# path on stdout and exit non-zero if none exists. `--stable` prints the
# canonical stable path regardless of existence (used by the setup wizard to
# decide where to write). Skills can call:
#   CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "${1:-}" = "--stable" ]; then
    obsidian_config_stable_path
    exit 0
  fi
  resolve_obsidian_config "${1:-${CLAUDE_PLUGIN_ROOT:-}}"
  exit $?
fi
