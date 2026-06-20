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

echo "PASS: keeper-bootstrap"
