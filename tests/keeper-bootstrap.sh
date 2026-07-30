#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "${ROOT_DIR}/scripts/lib/keeper-bootstrap.sh"
INSTALLER="${ROOT_DIR}/scripts/install-watcher.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kb-XXXXXX")"
# Two arms below chmod a config dir read-only. rm -rf clears it anyway on macOS
# 15 as the owner (verified — no crumb is left), but that is a permission detail
# this teardown should not depend on to avoid stranding a dir in the real TMPDIR.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

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
# the contrast just above it in production: the schema seed already names its
# fallback when it fails.
ROD="$WORK/ro"; mkdir -p "$ROD"
RCFG="$ROD/obsidian.local.md"; RVAULT="$WORK/vaultro"
printf -- '---\nvault_path: %s\n---\n' "$RVAULT" > "$RCFG"
mk_vault "$RVAULT"
export VAULTKEEPER_INSTALL="$WORK/stub-install.sh"
# Root writes straight through a read-only directory, so under root this arm and the
# one below it would assert on a write that SUCCEEDED and pass without testing
# anything (#47). Skipped loudly rather than left to pass vacuously.
if [ "$(id -u)" = "0" ]; then
  echo "note: running as root, skipping the read-only-config arms" >&2
else
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
fi

# --- _kb_cfg_ensure when mktemp itself cannot resolve TMPDIR (#47) ---
# The other half of the same failure, and the genuinely silent one: with an
# unresolvable TMPDIR there is no temp to leak and no `mv` to fail, so the write
# simply does not happen. Root-safe — no permission bit is involved — which is why
# this arm carries the invariant on hosts where the two above are skipped.
UCFG="$WORK/unresolvable.local.md"; UVAULT="$WORK/vaultunres"
printf -- '---\nvault_path: %s\n---\n' "$UVAULT" > "$UCFG"
mk_vault "$UVAULT"
if ( TMPDIR="$WORK/no/such/dir"; _kb_cfg_ensure unres_probe 1 "$UCFG" ); then
  fail "_kb_cfg_ensure reported success when mktemp could not resolve TMPDIR"
fi
grep -q 'unres_probe' "$UCFG" \
  && fail "_kb_cfg_ensure claims to have failed but the key is in the config: $(cat "$UCFG")"
UERR="$( TMPDIR="$WORK/no/such/dir" KEEPER_OS="Darwin" keeper_ensure_active "$UCFG" "$UVAULT" 900 2>&1 >/dev/null )" \
  || fail "ensure_active must stay non-zero-free when mktemp fails; a Stop hook cannot abort"
grep -q 'keeper_interval_secs' <<<"$UERR" \
  || fail "an unwritable-because-no-TMPDIR config write was silent: [$UERR]"

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

# --- the opt-out survives a broken pipeline stage (#45) ----------------------
# The single `|| autostart=""` had to absorb grep's exit 1 on a config without the
# key, but it absorbed a failure in `head` or `sed` too — and an empty autostart
# means "not false", so a broken stage silently overrode a documented opt-out and
# installed the scheduler. Break `sed` on PATH and the opt-out must still hold.
BSED="$WORK/brokensed"; mkdir -p "$BSED"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BSED/sed"; chmod +x "$BSED/sed"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BSED/head"; chmod +x "$BSED/head"
: > "$CALLS2"
PATH="$BSED:$PATH" KEEPER_OS="Darwin" keeper_ensure_active "$CFG2" "$VAULT2" 900 2>/dev/null \
  || fail "a broken pipeline stage must not make ensure_active non-zero"
[ ! -s "$CALLS2" ] \
  || fail "a broken sed/head overrode keeper_autostart:false and installed anyway: $(cat "$CALLS2")"

# …and the same for a value that is neither true nor false. Guessing "install"
# there installs a scheduler against something the user typed on purpose.
CFG3="$WORK/typo.local.md"; VAULT3="$WORK/vault3"
printf -- '---\nvault_path: %s\nkeeper_autostart: flase\n---\n' "$VAULT3" > "$CFG3"
mk_vault "$VAULT3"
: > "$CALLS2"
TERR="$(KEEPER_OS="Darwin" keeper_ensure_active "$CFG3" "$VAULT3" 900 2>&1 >/dev/null)" \
  || fail "an unrecognised keeper_autostart made ensure_active non-zero"
[ ! -s "$CALLS2" ] \
  || fail "an unrecognised keeper_autostart was treated as consent to install: $(cat "$CALLS2")"
grep -q 'keeper_autostart' <<<"$TERR" \
  || fail "an unrecognised keeper_autostart was skipped silently: [$TERR]"

# An explicit true still installs — the refusal above must not swallow the yes.
CFG4="$WORK/explicit.local.md"; VAULT4="$WORK/vault4"
printf -- '---\nvault_path: %s\nkeeper_autostart: true\n---\n' "$VAULT4" > "$CFG4"
mk_vault "$VAULT4"
: > "$CALLS2"
KEEPER_OS="Darwin" keeper_ensure_active "$CFG4" "$VAULT4" 900 2>/dev/null \
  || fail "ensure_active returned non-zero on an explicit keeper_autostart: true"
[ -s "$CALLS2" ] \
  || fail "keeper_autostart: true did not install"

# --- the seed's reason reaches the user, and it retries (#46) -----------------
# `>/dev/null 2>&1` meant a degraded seed printed a fallback notice that never said
# WHY — the one thing needed to fix it. And the seed sat below the installed-gate
# while documenting itself as one-time, so a seed that produced nothing usable during
# the single activation session was never retried on that host.
SDIR="$WORK/seedscripts"; mkdir -p "$SDIR/lib"
cp "${ROOT_DIR}"/scripts/*.sh "$SDIR/" 2>/dev/null || true
cp -R "${ROOT_DIR}/scripts/lib/." "$SDIR/lib/"
cat > "$SDIR/seed-frontmatter-schema.sh" <<'EOF'
#!/usr/bin/env bash
printf 'seed-frontmatter-schema: SEED-SAID-THIS\n' >&2
exit 1
EOF
chmod +x "$SDIR/seed-frontmatter-schema.sh"
SCFG="$WORK/seed.local.md"; SVAULT="$WORK/vaultseed"
printf -- '---\nvault_path: %s\n---\n' "$SVAULT" > "$SCFG"
mk_vault "$SVAULT"
: > "$CALLS2"
SERR="$(KEEPER_OS="Darwin" bash -c ". '$SDIR/lib/keeper-bootstrap.sh'; keeper_ensure_active '$SCFG' '$SVAULT' 900" 2>&1 >/dev/null)" \
  || fail "a failing seed must not make ensure_active non-zero"
grep -q 'SEED-SAID-THIS' <<<"$SERR" \
  || fail "the seed's own words were discarded, so the notice cannot be acted on: [$SERR]"

# Retry on a host where the scheduler is ALREADY installed: the seed must still run,
# because that is precisely the host that can never retry otherwise.
# Drive the suite's existing launchctl stub rather than replacing it: it reads
# $LAUNCHCTL_STATE, and the predicate matches the label as the LAST field.
SLABEL="$(bash "${ROOT_DIR}/scripts/install-watcher.sh" label)"
printf '%s\t%s\t%s\n' 123 0 "$SLABEL" > "$STATE"
# Clear the install log first: the not-installed call above legitimately installed,
# and the assertion below is about THIS call.
: > "$CALLS2"
SERR2="$(KEEPER_OS="Darwin" bash -c ". '$SDIR/lib/keeper-bootstrap.sh'; keeper_ensure_active '$SCFG' '$SVAULT' 900" 2>&1 >/dev/null)" \
  || fail "ensure_active went non-zero on an installed host with a failing seed"
grep -q 'SEED-SAID-THIS' <<<"$SERR2" \
  || fail "an installed host skipped the seed, so a bad value there is permanent: [$SERR2]"
# …and it really was the installed path: the gate returned before the installer ran.
# Without this the arm above passes on a host the gate never recognised as installed,
# which is not the case #46 is about.
[ ! -s "$CALLS2" ] \
  || fail "the launchctl stub did not make this an installed host, so the retry arm proves nothing: $(cat "$CALLS2")"

# …but a config that already HAS a usable value must not spawn the seed at all —
# that is the per-session cost this ordering has to stay cheap about.
printf -- '---\nvault_path: %s\nfrontmatter_required: tags type\n---\n' "$SVAULT" > "$SCFG"
SERR3="$(KEEPER_OS="Darwin" bash -c ". '$SDIR/lib/keeper-bootstrap.sh'; keeper_ensure_active '$SCFG' '$SVAULT' 900" 2>&1 >/dev/null)" \
  || fail "ensure_active went non-zero on a seeded host"
grep -q 'SEED-SAID-THIS' <<<"$SERR3" \
  && fail "a config with a usable frontmatter_required still spawned the seed: [$SERR3]"

# A present-but-empty value is NOT usable, and must retry.
printf -- '---\nvault_path: %s\nfrontmatter_required:\n---\n' "$SVAULT" > "$SCFG"
SERR4="$(KEEPER_OS="Darwin" bash -c ". '$SDIR/lib/keeper-bootstrap.sh'; keeper_ensure_active '$SCFG' '$SVAULT' 900" 2>&1 >/dev/null)" \
  || fail "ensure_active went non-zero on an empty-value host"
grep -q 'SEED-SAID-THIS' <<<"$SERR4" \
  || fail "a present-but-empty frontmatter_required was treated as seeded, so the host stays broken: [$SERR4]"
# Leave the shared stub in place for anything after this; just clear its state.
: > "$STATE"

# --- a plugin upgrade must not orphan the scheduler (#35) ---------------------
# The plist bakes in an ABSOLUTE, version-pinned tick path
# (…/cache/nhangen/obsidian/<version>/scripts/vaultkeeper-tick.sh) and a plugin update
# replaces that directory wholesale. `launchctl list` still shows the label, so the
# installed-gate returned forever while the program it named no longer existed: the
# keeper stopped ticking after every upgrade, on every host, and self-activation never
# repaired it.
UHOME="$WORK/uphome"; mkdir -p "$UHOME/Library/LaunchAgents"
UPL="$UHOME/Library/LaunchAgents/${LABEL}.plist"
UCFG2="$WORK/upgrade.local.md"; UVAULT2="$WORK/vaultupgrade"
printf -- '---\nvault_path: %s\nfrontmatter_required: tags type\n---\n' "$UVAULT2" > "$UCFG2"
mk_vault "$UVAULT2"
printf '%s\n' "$LABEL" > "$STATE"   # launchctl lists the label: "installed"
UTICK="${ROOT_DIR}/scripts/vaultkeeper-tick.sh"

# 1. Stale pin: the plist points into a version directory that is not this one.
bash "$INSTALLER" render-launchd "/cache/nhangen/obsidian/1.0.0/scripts/vaultkeeper-tick.sh" 900 > "$UPL"
: > "$CALLS2"
UERR2="$(HOME="$UHOME" KEEPER_OS="Darwin" keeper_ensure_active "$UCFG2" "$UVAULT2" 900 2>&1 >/dev/null)" \
  || fail "ensure_active went non-zero repairing a stale pin"
[ -s "$CALLS2" ] \
  || fail "an installed-but-stale scheduler was left alone; the keeper stays dead after every upgrade"
grep -q '1.0.0' <<<"$UERR2" \
  || fail "the repair did not name the stale path it found: [$UERR2]"

# 2. Current pin: nothing to do, and no reinstall.
bash "$INSTALLER" render-launchd "$UTICK" 900 > "$UPL"
: > "$CALLS2"
HOME="$UHOME" KEEPER_OS="Darwin" keeper_ensure_active "$UCFG2" "$UVAULT2" 900 2>/dev/null \
  || fail "ensure_active went non-zero on a correctly pinned host"
[ ! -s "$CALLS2" ] \
  || fail "a correctly pinned scheduler was reinstalled anyway: $(cat "$CALLS2")"

# 3. A deliberate wrapper is the right answer to this problem, not a stale pin.
#    Re-pinning over it would undo the very mitigation (#44), and it must be silent —
#    this runs every session, and a working setup is not a fault to report.
cat > "$UPL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${UHOME}/.claude/hooks/obsidian-vaultkeeper-tick.sh</string>
  </array>
</dict>
</plist>
EOF
: > "$CALLS2"
WERR="$(HOME="$UHOME" KEEPER_OS="Darwin" keeper_ensure_active "$UCFG2" "$UVAULT2" 900 2>&1 >/dev/null)" \
  || fail "ensure_active went non-zero on a wrapper host"
[ ! -s "$CALLS2" ] \
  || fail "a deliberate delegator was re-pinned over, undoing the #35 mitigation: $(cat "$CALLS2")"
[ -z "$WERR" ] \
  || fail "a working wrapper setup was reported as a problem every session: [$WERR]"
# 4. Listed, but no program is readable — no plist, or one we cannot parse. That is
#    not evidence of a stale pin, and reinstalling on it would clobber whatever is
#    actually there on a guess.
rm -f "$UPL"
: > "$CALLS2"
NERR="$(HOME="$UHOME" KEEPER_OS="Darwin" keeper_ensure_active "$UCFG2" "$UVAULT2" 900 2>&1 >/dev/null)" \
  || fail "ensure_active went non-zero when no plist was readable"
[ ! -s "$CALLS2" ] \
  || fail "an unreadable installed program was guessed to be stale and reinstalled: $(cat "$CALLS2")"
printf 'not a plist\n' > "$UPL"
: > "$CALLS2"
HOME="$UHOME" KEEPER_OS="Darwin" keeper_ensure_active "$UCFG2" "$UVAULT2" 900 2>/dev/null \
  || fail "ensure_active went non-zero on an unparseable plist"
[ ! -s "$CALLS2" ] \
  || fail "an unparseable plist was treated as a stale pin: $(cat "$CALLS2")"
: > "$STATE"

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

# --- a loud installer is still quoted, and the quote stays bounded (#41) ---
# The bound must not be a pipeline: `tr ... | head -c 300` makes head exit early,
# tr take SIGPIPE, and pipefail hand rc=141 to the assignment — so the `|| lblerr=""`
# fallback blanked a value that had been filled correctly. That is this PR's own
# subject (a diagnostic the shell throws away) reintroduced by its bound.
# 300 KB, and control bytes that must not reach the hook's stderr live.
LOUD="$WORK/loud/scripts"; mkdir -p "$LOUD/lib"
cp "${ROOT_DIR}/scripts/lib/keeper-bootstrap.sh" "$LOUD/lib/"
cat > "$LOUD/install-watcher.sh" <<'EOF'
#!/usr/bin/env bash
{ printf 'LOUD-HEAD\033[31m\r\a'; head -c 300000 /dev/zero | tr '\0' 'X'; printf 'LOUD-TAIL\n'; } >&2
exit 4
EOF
chmod +x "$LOUD/install-watcher.sh"
for _flags in 'set -uo pipefail;' 'set -euo pipefail;'; do
  LERR="$(KEEPER_OS="Darwin" bash -c "${_flags} . '$LOUD/lib/keeper-bootstrap.sh'; keeper_ensure_active '$BCFG' '$BVAULT' 900" 2>&1 >/dev/null)" \
    || fail "[$_flags] ensure_active must return 0 against a loud broken installer"
  grep -q 'LOUD-HEAD' <<<"$LERR" \
    || fail "[$_flags] the quote was dropped when the installer said too much: [${LERR:0:200}]"
  [ "${#LERR}" -lt 600 ] \
    || fail "[$_flags] refusal was ${#LERR} bytes; the quote is not bounded"
  case "$LERR" in
    *$'\r'*|*$'\a'*|*$'\033'*) fail "[$_flags] control bytes reached the hook's stderr: [${LERR:0:120}]" ;;
  esac
done

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
# Count mktemp too: capturing the installer's stderr unconditionally meant the
# working host paid a temp file per session to quote an installer with nothing to
# say. The spawn count alone does not see that.
MKC="$WORK/mktemp-calls.log"; : > "$MKC"
cat > "$WORK/bin/mktemp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MKC"
exec /usr/bin/mktemp "\$@"
EOF
chmod +x "$WORK/bin/mktemp"
printf '%s\n' "$LABEL" > "$STATE"
KEEPER_OS="Darwin" bash -c ". '$CNT/lib/keeper-bootstrap.sh'; keeper_ensure_active '$CFG' '$VAULT' 900" \
  || fail "ensure_active returned non-zero on an already-installed host"
[ ! -s "$MKC" ] \
  || fail "the session-end path on an installed host used mktemp: [$(cat "$MKC")]"
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
