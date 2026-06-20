#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
SH="${ROOT_DIR}/scripts/install-watcher.sh"
TICK="/abs/path/to/vaultkeeper-tick.sh"

PLIST="$(bash "$SH" render-launchd "$TICK" 900)"
grep -q 'com.nhangen.obsidian-vaultkeeper' <<<"$PLIST" || fail "plist missing namespace label"
grep -qF "$TICK" <<<"$PLIST" || fail "plist missing tick path"
grep -q '<integer>900</integer>' <<<"$PLIST" || fail "plist missing StartInterval"

CRON="$(bash "$SH" render-cron "$TICK" 900)"
grep -qF "$TICK" <<<"$CRON" || fail "cron line missing tick path"
grep -q '# com.nhangen.obsidian-vaultkeeper' <<<"$CRON" || fail "cron line missing namespace marker"

# Unknown subcommand must fail loudly (enum-config-typo-fallback discipline).
if bash "$SH" frobnicate "$TICK" 900 >/dev/null 2>&1; then
  fail "unknown subcommand should exit non-zero"
fi

echo "PASS: install-watcher"
