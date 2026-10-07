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
grep -qF "\"$TICK\"" <<<"$CRON" || fail "cron line tick path not wrapped in double quotes"
grep -q '^\*/15 \* \* \* \* ' <<<"$CRON" || fail "cron line 900s missing */15 schedule: [$CRON]"

# Hourly cron rendering (#144)
CRON_3600="$(bash "$SH" render-cron "$TICK" 3600)"
grep -q '^0 \*/1 \* \* \* ' <<<"$CRON_3600" || fail "cron line 3600s missing 0 */1 schedule: [$CRON_3600]"
grep -qF "$TICK" <<<"$CRON_3600" || fail "cron line 3600s missing tick path"
grep -q '# com.nhangen.obsidian-vaultkeeper' <<<"$CRON_3600" || fail "cron line 3600s missing namespace marker"

CRON_7200="$(bash "$SH" render-cron "$TICK" 7200)"
grep -q '^0 \*/2 \* \* \* ' <<<"$CRON_7200" || fail "cron line 7200s missing 0 */2 schedule: [$CRON_7200]"
grep -qF "$TICK" <<<"$CRON_7200" || fail "cron line 7200s missing tick path"

# Refusal of intervals cron cannot express (#144)
if bash "$SH" render-cron "$TICK" 5400 >/dev/null 2>&1; then
  fail "render-cron 5400 (90m) should exit non-zero"
fi
if bash "$SH" render-cron "$TICK" 2700 >/dev/null 2>&1; then
  fail "render-cron 2700 (45m) should exit non-zero"
fi
if bash "$SH" render-cron "$TICK" 18000 >/dev/null 2>&1; then
  fail "render-cron 18000 (5h) should exit non-zero"
fi
if bash "$SH" render-cron "$TICK" 30 >/dev/null 2>&1; then
  fail "render-cron 30 (sub-minute) should exit non-zero"
fi
if bash "$SH" render-cron "$TICK" 0 >/dev/null 2>&1; then
  fail "render-cron 0 should exit non-zero"
fi
if bash "$SH" render-cron "$TICK" "invalid" >/dev/null 2>&1; then
  fail "render-cron invalid should exit non-zero"
fi

# Unknown subcommand must fail loudly (enum-config-typo-fallback discipline).
if bash "$SH" frobnicate "$TICK" 900 >/dev/null 2>&1; then
  fail "unknown subcommand should exit non-zero"
fi

# The rendered plist carries log paths. The 700+ ticks that logged "Too many open
# files" above "scan complete" (#42) were read out of exactly these, on a plist a
# human had written; a rendered one recorded nothing.
grep -q '<key>StandardOutPath</key>' <<<"$PLIST" || fail "plist has no StandardOutPath, so a fault on an unwatched host leaves no record"
grep -q '<key>StandardErrorPath</key>' <<<"$PLIST" || fail "plist has no StandardErrorPath"

# --- refuse to replace a plist this script did not render (#44) ---------------
# The live host points ProgramArguments at a hand-written delegator that resolves
# the newest versioned plugin dir — the local mitigation for #35 — and carries the
# log redirect. install_watcher rendered neither, so any path reaching it silently
# swapped the delegator for a version-pinned path and printed "activated", which
# strands the pin on the next plugin update: #35, reintroduced by the installer.
HOMEDIR="$(mktemp -d "${TMPDIR:-/tmp}/iw-home-XXXXXX")"
cleanup() { rm -rf "${HOMEDIR:-}" "${CRON_DIR:-}"; }
trap cleanup EXIT
mkdir -p "$HOMEDIR/Library/LaunchAgents" "$HOMEDIR/bin"
PL="$HOMEDIR/Library/LaunchAgents/com.nhangen.obsidian-vaultkeeper.plist"
# A launchctl that always succeeds, so the only thing under test is the refusal.
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOMEDIR/bin/launchctl"; chmod +x "$HOMEDIR/bin/launchctl"

write_delegator_plist() {
  cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.nhangen.obsidian-vaultkeeper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${HOMEDIR}/.claude/hooks/obsidian-vaultkeeper-tick.sh</string>
  </array>
  <key>StandardOutPath</key><string>${HOMEDIR}/keeper.log</string>
</dict>
</plist>
EOF
}

write_delegator_plist
BEFORE="$(cat "$PL")"
IERR="$( HOME="$HOMEDIR" PATH="$HOMEDIR/bin:$PATH" bash "$SH" install "$TICK" 900 2>&1 )" \
  && fail "install replaced a plist it did not render and reported success: $IERR"
[ "$(cat "$PL")" = "$BEFORE" ] \
  || fail "the delegator plist was modified despite the refusal:"$'\n'"$(cat "$PL")"
grep -q 'did not render' <<<"$IERR" \
  || fail "the refusal did not say why: [$IERR]"
grep -qF 'obsidian-vaultkeeper-tick.sh' <<<"$IERR" \
  || fail "the refusal did not name the program it found: [$IERR]"

# …but a plist WE rendered is replaceable, or the #35 self-heal breaks: our own path
# is version-pinned into the plugin cache and legitimately changes on every update.
bash "$SH" render-launchd "/old/version/1.0.0/scripts/vaultkeeper-tick.sh" 900 > "$PL"
HOME="$HOMEDIR" PATH="$HOMEDIR/bin:$PATH" bash "$SH" install "/new/version/2.0.0/scripts/vaultkeeper-tick.sh" 900 >/dev/null 2>&1 \
  || fail "install refused to replace a plist it had rendered itself, which blocks the #35 re-install"
grep -qF '/new/version/2.0.0/scripts/vaultkeeper-tick.sh' "$PL" \
  || fail "the re-install did not update the pinned tick path: $(cat "$PL")"

# A first install on a host with no plist at all must still work.
rm -f "$PL"
HOME="$HOMEDIR" PATH="$HOMEDIR/bin:$PATH" bash "$SH" install "$TICK" 900 >/dev/null 2>&1 \
  || fail "install failed on a host with no existing plist"
[ -f "$PL" ] || fail "install wrote no plist on a clean host"

# An existing plist we cannot parse a program out of is not ours to guess about.
printf 'not a plist at all\n' > "$PL"
BEFORE2="$(cat "$PL")"
HOME="$HOMEDIR" PATH="$HOMEDIR/bin:$PATH" bash "$SH" install "$TICK" 900 >/dev/null 2>&1 \
  && fail "install overwrote an unparseable plist"
[ "$(cat "$PL")" = "$BEFORE2" ] || fail "an unparseable plist was overwritten anyway"

# --- `state` answers label + installed program in one spawn (#35) -------------
# keeper_ensure_active needs both, and an installed host is meant to cost exactly one
# installer spawn per session.
ST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/iw-state-XXXXXX")"
mkdir -p "$ST_HOME/Library/LaunchAgents"
ST_PL="$ST_HOME/Library/LaunchAgents/com.nhangen.obsidian-vaultkeeper.plist"
# No entry at all: the label is still first, the program field empty.
ST_OUT="$(HOME="$ST_HOME" bash "$SH" state)"
[ "${ST_OUT%%$'	'*}" = "com.nhangen.obsidian-vaultkeeper" ]   || fail "state did not put the label first: [$ST_OUT]"
[ -z "${ST_OUT#*$'	'}" ]   || fail "state reported a program when nothing is installed: [$ST_OUT]"
# With an entry, the program is the tick path from ProgramArguments — not /bin/bash.
bash "$SH" render-launchd "/some/version/scripts/vaultkeeper-tick.sh" 900 > "$ST_PL"
ST_OUT2="$(HOME="$ST_HOME" bash "$SH" state)"
[ "${ST_OUT2#*$'	'}" = "/some/version/scripts/vaultkeeper-tick.sh" ]   || fail "state did not report the installed program: [$ST_OUT2]"
HOME="$ST_HOME" bash "$SH" installed-program | grep -qF '/some/version/scripts/vaultkeeper-tick.sh'   || fail "installed-program disagreed with state"
rm -rf "$ST_HOME"

# --- Linux crontab install, replace, and refuse (#44, #144) ------------------
CRON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iw-cron-XXXXXX")"
mkdir -p "$CRON_DIR/bin"
CRON_TAB="$CRON_DIR/crontab.txt"

cat > "$CRON_DIR/bin/crontab" <<'EOF'
#!/usr/bin/env bash
FILE="${CRON_TAB_FILE:?missing CRON_TAB_FILE}"
case "${1:-}" in
  -l)
    if [ -f "$FILE" ]; then
      cat "$FILE"
      exit 0
    fi
    exit 1
    ;;
  -)
    cat > "$FILE"
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$CRON_DIR/bin/crontab"

cat > "$CRON_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then
  echo "Linux"
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
chmod +x "$CRON_DIR/bin/uname"

# 1. Clean install with 900s
PATH="$CRON_DIR/bin:$PATH" CRON_TAB_FILE="$CRON_TAB" bash "$SH" install "$TICK" 900 >/dev/null 2>&1 \
  || fail "Linux clean install failed"
grep -q '^[*]/15 \* \* \* \* ' "$CRON_TAB" || fail "crontab missing */15 schedule: $(cat "$CRON_TAB")"

# 2. Re-install with 3600s replaces the sub-hourly line with 0 */1
PATH="$CRON_DIR/bin:$PATH" CRON_TAB_FILE="$CRON_TAB" bash "$SH" install "$TICK" 3600 >/dev/null 2>&1 \
  || fail "Linux reinstall with 3600 failed"
grep -q '^0 [*]/1 \* \* \* ' "$CRON_TAB" || fail "crontab missing 0 */1 schedule: $(cat "$CRON_TAB")"
[ "$(grep -c 'com.nhangen.obsidian-vaultkeeper' "$CRON_TAB")" -eq 1 ] \
  || fail "crontab duplicated marker line: $(cat "$CRON_TAB")"

# 3. Replace hand-edited hourly line (0 * * * *)
printf '0 * * * * /bin/bash "%s" >/dev/null 2>&1 # com.nhangen.obsidian-vaultkeeper\n' "$TICK" > "$CRON_TAB"
PATH="$CRON_DIR/bin:$PATH" CRON_TAB_FILE="$CRON_TAB" bash "$SH" install "$TICK" 7200 >/dev/null 2>&1 \
  || fail "Linux install failed to replace hand-edited 0 * * * * line"
grep -q '^0 [*]/2 \* \* \* ' "$CRON_TAB" || fail "crontab did not update to 0 */2: $(cat "$CRON_TAB")"

# 4. Refuse to replace a cron line running an unrendered delegator / foreign script (#44)
printf '0 * * * * /bin/bash "/some/path/obsidian-vaultkeeper-tick.sh" >/dev/null 2>&1 # com.nhangen.obsidian-vaultkeeper\n' > "$CRON_TAB"
BEFORE_CRON="$(cat "$CRON_TAB")"
if PATH="$CRON_DIR/bin:$PATH" CRON_TAB_FILE="$CRON_TAB" bash "$SH" install "$TICK" 900 >/dev/null 2>&1; then
  fail "Linux install should refuse to replace delegator script"
fi
[ "$(cat "$CRON_TAB")" = "$BEFORE_CRON" ] || fail "Linux install modified crontab despite refusal"

# 5. Refuse unexpressible interval on install (e.g. 5400s)
printf '*/15 * * * * /bin/bash "%s" >/dev/null 2>&1 # com.nhangen.obsidian-vaultkeeper\n' "$TICK" > "$CRON_TAB"
BEFORE_CRON2="$(cat "$CRON_TAB")"
if PATH="$CRON_DIR/bin:$PATH" CRON_TAB_FILE="$CRON_TAB" bash "$SH" install "$TICK" 5400 >/dev/null 2>&1; then
  fail "Linux install should refuse unexpressible interval 5400s"
fi
[ "$(cat "$CRON_TAB")" = "$BEFORE_CRON2" ] || fail "Linux install modified crontab on refused interval"

# 6. installed-program and state on Linux report the tick path
PATH="$CRON_DIR/bin:$PATH" CRON_TAB_FILE="$CRON_TAB" bash "$SH" installed-program | grep -qF "$TICK" \
  || fail "Linux installed-program did not find tick path"
L_STATE="$(PATH="$CRON_DIR/bin:$PATH" CRON_TAB_FILE="$CRON_TAB" bash "$SH" state)"
[ "${L_STATE%%$'	'*}" = "com.nhangen.obsidian-vaultkeeper" ] || fail "Linux state bad label: [$L_STATE]"
[ "${L_STATE#*$'	'}" = "$TICK" ] || fail "Linux state bad program: [$L_STATE]"

rm -rf "$CRON_DIR"

echo "PASS: install-watcher"
