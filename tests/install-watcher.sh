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

# Cron cannot express every interval (#144): hourly and longer must not render */60.
cron_spec() { bash "$SH" render-cron "$TICK" "$1" | cut -d' ' -f1-5; }
[ "$(cron_spec 900)" = '*/15 * * * *' ] || fail "900s should render */15"
[ "$(cron_spec 3600)" = '0 * * * *' ] || fail "3600s should render hourly, got $(cron_spec 3600)"
[ "$(cron_spec 7200)" = '0 */2 * * *' ] || fail "7200s should render 0 */2"
[ "$(cron_spec 86400)" = '0 0 * * *' ] || fail "86400s should render daily, got $(cron_spec 86400)"
[ "$(cron_spec 0900)" = '*/15 * * * *' ] || fail "0900 must not be read as octal"
[ "$(cron_spec 30)" = '* * * * *' ] || fail "sub-minute interval should render every minute"
[ "$(cron_spec 60)" = '*/1 * * * *' ] || fail "60s should render */1"
[ "$(cron_spec 43200)" = '0 */12 * * *' ] || fail "43200s should render 0 */12"
for bad in 5400 420 90 18000 172800 abc; do
  if out="$(bash "$SH" render-cron "$TICK" "$bad" 2>/dev/null)"; then fail "interval $bad should be refused"; fi
  [ -z "$out" ] || fail "refused interval $bad must print no cron line, got: $out"
done

# Drive the cron `install` branch with a stubbed uname and crontab (#144). The suite
# otherwise only stubs launchctl, so a refused interval that wrote an empty line
# would pass.
CRONDIR="$(mktemp -d "${TMPDIR:-/tmp}/iw-cron-XXXXXX")"
mkdir -p "$CRONDIR/bin"
printf '#!/usr/bin/env bash\necho Linux\n' > "$CRONDIR/bin/uname"
cat > "$CRONDIR/bin/crontab" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-l" ]; then cat "$CRONDIR/crontab" 2>/dev/null; exit 0; fi
cat > "$CRONDIR/crontab.new" && mv "$CRONDIR/crontab.new" "$CRONDIR/crontab"
STUB
chmod +x "$CRONDIR/bin/uname" "$CRONDIR/bin/crontab"
LABEL_MARK='# com.nhangen.obsidian-vaultkeeper'
printf '0 1 * * * /usr/bin/other\n*/15 * * * * /bin/bash "%s" >/dev/null 2>&1 %s\n' "$TICK" "$LABEL_MARK" > "$CRONDIR/crontab"
BEFORE="$(cat "$CRONDIR/crontab")"
if PATH="$CRONDIR/bin:$PATH" bash "$SH" install "$TICK" 5400 >/dev/null 2>&1; then fail "install of a refused interval should exit non-zero"; fi
[ "$(cat "$CRONDIR/crontab")" = "$BEFORE" ] || fail "a refused install must leave the crontab untouched"
PATH="$CRONDIR/bin:$PATH" bash "$SH" install "$TICK" 3600 >/dev/null 2>&1 || fail "install of 3600 should succeed over an existing */15 line"
[ "$(grep -cF "$LABEL_MARK" "$CRONDIR/crontab")" = 1 ] || fail "re-install must leave exactly one watcher line"
grep -q '^0 \* \* \* \* ' "$CRONDIR/crontab" || fail "re-install should write the hourly line"
grep -qF '/usr/bin/other' "$CRONDIR/crontab" || fail "re-install dropped an unrelated crontab entry"

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
trap 'rm -rf "$HOMEDIR" "$CRONDIR"' EXIT
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

echo "PASS: install-watcher"
