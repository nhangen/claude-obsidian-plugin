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

# Read a scalar `key: value` out of the resolved config's frontmatter. Echoes
# the trimmed value; returns 1 when no config resolves or the key is absent, so
# a caller can tell "unset" (use my default) from "set". Config keys documented
# in a SKILL and written by setup were otherwise read by whichever call site
# remembered to (#103) — dedup_jaccard_threshold reached none of its three.
obsidian_config_value() {
  local key="$1" cfg v
  cfg="$(resolve_obsidian_config "${2:-${CLAUDE_PLUGIN_ROOT:-}}")" || return 1
  v="$(awk -v k="$key" '
    index($0, k ":") == 1 {
      sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }' "$cfg")"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# CLI mode: when executed directly (not sourced), print the resolved config
# path on stdout and exit non-zero if none exists. `--stable` prints the
# canonical stable path regardless of existence (used by the setup wizard to
# decide where to write). Skills can call:
#   CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh")"
# This one stays a bare BASH_SOURCE comparison, unlike the source-time captures in
# allowlist-validate.sh / keeper-bootstrap.sh / vault-scan.sh. Do NOT "fix" it to
# `${BASH_SOURCE[0]:-$0}`: under zsh that compares $0 to itself, the branch fires
# while merely being sourced, and the `exit` below kills the sourcing shell — which
# is session-save.sh, the Stop hook. Six bash scripts source this file. The `:-`
# below is only for `set -u` safety; it leaves the comparison false under zsh,
# which is correct in both directions there.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  if [ "${1:-}" = "--stable" ]; then
    obsidian_config_stable_path
    exit 0
  fi
  resolve_obsidian_config "${1:-${CLAUDE_PLUGIN_ROOT:-}}"
  exit $?
fi
