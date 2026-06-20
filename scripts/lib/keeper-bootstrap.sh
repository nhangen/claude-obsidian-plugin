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

_kb_scripts() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

# Single source of truth for the namespace label: install-watcher.sh owns it.
keeper_label() { bash "$(_kb_scripts)/install-watcher.sh" label 2>/dev/null; }

keeper_scheduler_installed() {
  local os="${KEEPER_OS:-$(uname -s)}" label
  label="$(keeper_label)"
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
  ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# keeper_ensure_active <config_file> <vault_path> [interval_secs]
keeper_ensure_active() {
  local cfg="$1" vault="$2" interval="${3:-900}"
  [ -f "$cfg" ] && [ -d "$vault" ] || return 0

  local autostart
  autostart="$(grep '^keeper_autostart:' "$cfg" | head -1 | sed 's/^keeper_autostart:[[:space:]]*//')"
  [ "$autostart" = "false" ] && return 0

  # A missing/empty label means the installer is broken — that's an error to
  # report, not a "not installed" signal to barrel past into a doomed install.
  local label; label="$(keeper_label)"
  if [ -z "$label" ]; then
    printf 'vaultkeeper: cannot resolve scheduler label (install-watcher.sh broken?); skipping activation\n' >&2
    return 0
  fi

  keeper_scheduler_installed && return 0

  local scripts; scripts="$(_kb_scripts)"
  local tick="$scripts/vaultkeeper-tick.sh"
  if ! bash "$scripts/seed-frontmatter-schema.sh" "$vault" "$cfg" >/dev/null 2>&1; then
    printf 'vaultkeeper: frontmatter-schema seed failed; using default (tags type)\n' >&2
  fi
  _kb_cfg_ensure keeper_autostart true "$cfg" || true
  _kb_cfg_ensure keeper_interval_secs "$interval" "$cfg" || true

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
