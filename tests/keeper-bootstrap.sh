#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "${ROOT_DIR}/scripts/lib/keeper-bootstrap.sh"
INSTALLER="${ROOT_DIR}/scripts/install-watcher.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kb-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# install-watcher.sh exposes the namespace label, and the bootstrap lib reads
# from it — one source of truth, no drift between the two files.
LABEL="$(bash "$INSTALLER" label)"
[ "$LABEL" = "com.nhangen.obsidian-vaultkeeper" ] || fail "installer label drifted: '$LABEL'"
[ "$(keeper_label)" = "$LABEL" ] || fail "bootstrap label '$(keeper_label)' != installer label '$LABEL'"

# Stub launchctl so the macOS detection branch reads LIVE state from a file we
# control (a not-running agent must read as absent, not from a stale plist).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "list" ] || exit 0
cat "${LAUNCHCTL_STATE:-/dev/null}" 2>/dev/null || true
EOF
chmod +x "$WORK/bin/launchctl"
export PATH="$WORK/bin:$PATH"
STATE="$WORK/lc-state"; : > "$STATE"; export LAUNCHCTL_STATE="$STATE"

# --- keeper_scheduler_installed reads live launchctl state, not a plist file ---
if KEEPER_OS="Darwin" keeper_scheduler_installed; then
  fail "scheduler reported installed when launchctl lists nothing"
fi
printf '%s\n' "$LABEL" > "$STATE"
if ! KEEPER_OS="Darwin" keeper_scheduler_installed; then
  fail "scheduler reported absent when launchctl lists the label"
fi
: > "$STATE"   # back to not-installed for the ensure tests

# --- install-contract: render output must satisfy the detection grep patterns
# (locks the production install dispatch the ensure tests stub out, F5/F6) ---
PLIST="$(bash "$INSTALLER" render-launchd "/x/tick.sh" 900)"
grep -qF "$LABEL" <<<"$PLIST"            || fail "render-launchd missing label"
grep -qF "/x/tick.sh" <<<"$PLIST"        || fail "render-launchd missing tick path"
grep -q '<integer>900</integer>' <<<"$PLIST" || fail "render-launchd missing interval"
CRON="$(bash "$INSTALLER" render-cron "/x/tick.sh" 900)"
# the cron detection branch greps "# ${label}" — assert render-cron emits exactly that
grep -qF "# ${LABEL}" <<<"$CRON" || fail "render-cron marker != cron-detection grep pattern '# ${LABEL}'"

# --- keeper_ensure_active: clean state seeds + installs exactly once ---
mk_vault() {
  local v="$1"; mkdir -p "$v"
  printf -- '---\ntags: [a]\ntype: note\n---\nbody\n' > "$v/one.md"
  printf -- '---\ntags: [b]\ntype: note\n---\nbody\n' > "$v/two.md"
}

CFG="$WORK/obsidian.local.md"; VAULT="$WORK/vault"
printf -- '---\nvault_path: %s\nauto_save: true\n---\n' "$VAULT" > "$CFG"
mk_vault "$VAULT"
CALLS="$WORK/install-calls.log"; : > "$CALLS"
export VAULTKEEPER_INSTALL="$WORK/stub-install.sh"
cat > "$VAULTKEEPER_INSTALL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
EOF
chmod +x "$VAULTKEEPER_INSTALL"

run_ensure() { KEEPER_OS="Darwin" keeper_ensure_active "$CFG" "$VAULT" 900; }

run_ensure || fail "ensure_active returned non-zero on clean state"
grep -q '^frontmatter_required:' "$CFG" || fail "schema not seeded into config"
grep -q '^keeper_autostart:' "$CFG" || fail "keeper_autostart default not written"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = "1" ] || fail "expected exactly one install call, got $(cat "$CALLS")"
grep -q 'vaultkeeper-tick.sh' "$CALLS" || fail "install call missing tick path"

# Simulate the agent now being loaded, then re-run: must be a no-op.
printf '%s\n' "$LABEL" > "$STATE"
run_ensure || fail "ensure_active returned non-zero when already installed"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = "1" ] \
  || fail "ensure_active re-installed when already active (not idempotent): $(cat "$CALLS")"
: > "$STATE"

# --- failed install is surfaced (not silent) and not recorded as success ---
FAILCALLS="$WORK/fail-calls.log"; : > "$FAILCALLS"
export VAULTKEEPER_INSTALL="$WORK/stub-fail.sh"
cat > "$VAULTKEEPER_INSTALL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FAILCALLS"
exit 1
EOF
chmod +x "$VAULTKEEPER_INSTALL"
CFGF="$WORK/fail.local.md"; VAULTF="$WORK/vaultf"
printf -- '---\nvault_path: %s\n---\n' "$VAULTF" > "$CFGF"
mk_vault "$VAULTF"
ERR="$(KEEPER_OS="Darwin" keeper_ensure_active "$CFGF" "$VAULTF" 900 2>&1 >/dev/null)" \
  || fail "ensure_active must return 0 even when install fails (never abort the hook)"
[ -s "$FAILCALLS" ] || fail "failing install was never attempted"
grep -qi 'FAILED' <<<"$ERR" || fail "failed install was silent — no diagnostic emitted: '$ERR'"

# --- a failed config write leaves a trace (#40) ---
# A read-only parent dir makes _kb_cfg_ensure's `mv` fail the way a full or
# permission-denied filesystem does. Staying non-fatal is correct — a Stop hook
# must not abort — but the config then never gains keeper_interval_secs and the
# keeper runs at the compiled-in default forever, so it cannot be silent. Note
# the contrast one line up in production: the schema seed already names its
# fallback when it fails.
ROD="$WORK/ro"; mkdir -p "$ROD"
RCFG="$ROD/obsidian.local.md"; RVAULT="$WORK/vaultro"
printf -- '---\nvault_path: %s\n---\n' "$RVAULT" > "$RCFG"
mk_vault "$RVAULT"
export VAULTKEEPER_INSTALL="$WORK/stub-install.sh"
chmod a-w "$ROD"
RERR="$(KEEPER_OS="Darwin" keeper_ensure_active "$RCFG" "$RVAULT" 900 2>&1 >/dev/null)" \
  || { chmod u+w "$ROD"; fail "ensure_active must return 0 when a config write fails"; }
chmod u+w "$ROD"
grep -q 'keeper_autostart' <<<"$RERR" \
  || fail "failed keeper_autostart write was silent: [$RERR]"
grep -q 'keeper_interval_secs' <<<"$RERR" \
  || fail "failed keeper_interval_secs write was silent: [$RERR]"

# --- _kb_cfg_ensure cleans up its temp file when the swap fails (#40) ---
# awk succeeds, `mv` fails, and the rendered config sits in TMPDIR forever. The
# Stop hook runs this on every session, so the leak accumulates one file per
# session for as long as the config stays unwritable. Subshell so the temporary
# TMPDIR cannot outlive the call.
LEAK="$WORK/leaktmp"; mkdir -p "$LEAK"
chmod a-w "$ROD"
if ( TMPDIR="$LEAK"; _kb_cfg_ensure leak_probe 1 "$RCFG" ); then
  chmod u+w "$ROD"; fail "_kb_cfg_ensure reported success when mv could not write the config"
fi
chmod u+w "$ROD"
LEFT="$(find "$LEAK" -name 'kbcfg-*' -type f | wc -l | tr -d ' ')"
[ "$LEFT" = "0" ] || fail "_kb_cfg_ensure leaked $LEFT temp file(s) into $LEAK"

# --- opt-out: keeper_autostart: false skips install entirely ---
CFG2="$WORK/optout.local.md"; VAULT2="$WORK/vault2"
printf -- '---\nvault_path: %s\nkeeper_autostart: false\n---\n' "$VAULT2" > "$CFG2"
mk_vault "$VAULT2"
CALLS2="$WORK/install-calls2.log"; : > "$CALLS2"
export VAULTKEEPER_INSTALL="$WORK/stub-install2.sh"
cat > "$VAULTKEEPER_INSTALL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS2"
EOF
chmod +x "$VAULTKEEPER_INSTALL"
KEEPER_OS="Darwin" keeper_ensure_active "$CFG2" "$VAULT2" 900 \
  || fail "ensure_active returned non-zero on opt-out config"
[ ! -s "$CALLS2" ] || fail "keeper_autostart:false still installed: $(cat "$CALLS2")"

# --- wiring: the Stop hook actually invokes the bootstrap ---
SAVE="${ROOT_DIR}/scripts/session-save.sh"
grep -q 'keeper-bootstrap.sh' "$SAVE" || fail "session-save.sh does not source keeper-bootstrap.sh"
grep -q 'keeper_ensure_active' "$SAVE" || fail "session-save.sh never calls keeper_ensure_active"

# --- self-location is shell- and cwd-independent ---
# The Stop hook sources this lib, and the librarian/keeper runtime is zsh, which
# has no BASH_SOURCE. Resolving the scripts dir from "." meant the lib only found
# its siblings when the caller happened to be standing in scripts/lib.
EXPECT="${ROOT_DIR}/scripts"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  GOT="$("$sh" -c "cd / && . '${ROOT_DIR}/scripts/lib/keeper-bootstrap.sh'; _kb_scripts" 2>/dev/null)"
  [ "$GOT" = "$EXPECT" ] || fail "$sh + foreign cwd: _kb_scripts gave [$GOT], want [$EXPECT]"
done

# A lib that cannot find its siblings must say so, not print an empty path and
# report success — both callers build `bash "$scripts/..."` from it unchecked, and
# the resulting empty-label branch used to blame install-watcher.sh by name.
ORPHAN="$WORK/orphan/lib"; mkdir -p "$ORPHAN"
cp "${ROOT_DIR}/scripts/lib/keeper-bootstrap.sh" "$ORPHAN/"
if bash -c ". '$ORPHAN/keeper-bootstrap.sh'; _kb_scripts" >"$WORK/orph.out" 2>/dev/null; then
  fail "_kb_scripts must fail when install-watcher.sh is not beside the lib, printed: [$(cat "$WORK/orph.out")]"
fi
[ -s "$WORK/orph.out" ] && fail "_kb_scripts printed a path on failure: [$(cat "$WORK/orph.out")]"
OERR="$(KEEPER_OS="Darwin" bash -c ". '$ORPHAN/keeper-bootstrap.sh'; keeper_ensure_active '$CFG' '$VAULT' 900" 2>&1 >/dev/null)" \
  || fail "keeper_ensure_active must still return 0 when self-location fails (never abort the hook)"
grep -q 'cannot find the scripts dir' <<<"$OERR" \
  || fail "self-location failure was not named; got: [$OERR]"
grep -q 'install-watcher.sh broken' <<<"$OERR" \
  && fail "self-location failure blamed install-watcher.sh: [$OERR]"

# --- a broken installer is reported in its own words (#40) ---
# _kb_scripts succeeds here — install-watcher.sh is present beside the lib — so
# this is the case #34 left behind: the installer itself is broken. Its stderr is
# the only thing separating a syntax error from a missing dependency, and
# `2>/dev/null` threw it away, leaving the refusal to guess "broken?".
BRK="$WORK/broken/scripts"; mkdir -p "$BRK/lib"
cp "${ROOT_DIR}/scripts/lib/keeper-bootstrap.sh" "$BRK/lib/"
cat > "$BRK/install-watcher.sh" <<'EOF'
#!/usr/bin/env bash
echo "BOOM-INSTALLER-DIAGNOSTIC" >&2
exit 3
EOF
# Both flag sets: session-save.sh is `set -uo pipefail` today, but an errexit
# caller aborted at `label="$(keeper_label ...)"` — the installer's exit 3 became
# the assignment's status — killing the hook before the refusal ever printed. A
# diagnostic the shell never reaches is the #34 defect, so pin both.
BCFG="$WORK/broken.local.md"; BVAULT="$WORK/vaultb"
printf -- '---\nvault_path: %s\n---\n' "$BVAULT" > "$BCFG"   # no keeper_autostart key
mk_vault "$BVAULT"
for _flags in '' 'set -euo pipefail;'; do
  BERR="$(KEEPER_OS="Darwin" bash -c "${_flags} . '$BRK/lib/keeper-bootstrap.sh'; keeper_ensure_active '$BCFG' '$BVAULT' 900" 2>&1 >/dev/null)" \
    || fail "[${_flags:-no flags}] ensure_active must return 0 when the installer is broken (never abort the hook)"
  grep -q 'BOOM-INSTALLER-DIAGNOSTIC' <<<"$BERR" \
    || fail "[${_flags:-no flags}] installer stderr was discarded; refusal said only: [$BERR]"
done
# Compare against the pwd-normalized path: _kb_lib_dir resolves through
# `cd && pwd`, so a TMPDIR with a trailing slash collapses "T//kb-x" to "T/kb-x".
BRKREAL="$(cd "$BRK" && pwd)"
grep -qF "$BRKREAL/install-watcher.sh" <<<"$BERR" \
  || fail "refusal did not name the installer it actually called: [$BERR]"

# --- the session-end path on a working host spawns the installer once (#41) ---
# Asking for the label twice — once in keeper_ensure_active, once inside the
# predicate it calls — put a second install-watcher.sh process on every activated
# host's Stop hook, alongside a mktemp/rm pair capturing stderr from an installer
# that had nothing to say. This is the dominant path: every session, forever.
CNT="$WORK/counted/scripts"; mkdir -p "$CNT/lib"
cp "${ROOT_DIR}/scripts/lib/keeper-bootstrap.sh" "$CNT/lib/"
SPAWNS="$WORK/label-spawns.log"; : > "$SPAWNS"
cat > "$CNT/install-watcher.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$SPAWNS"
printf '%s\n' "$LABEL"
EOF
chmod +x "$CNT/install-watcher.sh"
printf '%s\n' "$LABEL" > "$STATE"
KEEPER_OS="Darwin" bash -c ". '$CNT/lib/keeper-bootstrap.sh'; keeper_ensure_active '$CFG' '$VAULT' 900" \
  || fail "ensure_active returned non-zero on an already-installed host"
SPAWNED="$(wc -l < "$SPAWNS" | tr -d ' ')"
[ "$SPAWNED" = "1" ] \
  || fail "an installed host spawned install-watcher.sh $SPAWNED times per session, want 1"
: > "$STATE"

# --- the predicate answers; it never leaks the installer's status or stderr ---
# keeper_scheduler_installed is public (the launchctl arms above call it bare) and
# its `label="$(keeper_label)"` carried the installer's exit 3 as the assignment's
# status: an errexit caller died on that line and never reached the
# `[ -n "$label" ] || return 1` below it. In production the `&&` at the call site
# hid that positionally. A predicate also has no channel to explain a fault on, so
# the installer's stderr must not surface here unprefixed — keeper_ensure_active
# is the caller that quotes it.
PRC=0
PERR="$(KEEPER_OS="Darwin" bash -c "set -euo pipefail; . '$BRK/lib/keeper-bootstrap.sh'; keeper_scheduler_installed" 2>&1 >/dev/null)" || PRC=$?
[ "$PRC" = 1 ] \
  || fail "keeper_scheduler_installed returned the installer's status ($PRC), so the handler under the assignment was never reached"
[ -z "$PERR" ] \
  || fail "the predicate leaked the installer's stderr to its caller: [$PERR]"

echo "PASS: keeper-bootstrap"
