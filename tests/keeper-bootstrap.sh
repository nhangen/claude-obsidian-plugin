#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "${ROOT_DIR}/scripts/lib/keeper-bootstrap.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kb-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# install-watcher.sh exposes the namespace label, and the bootstrap lib reads
# from it — one source of truth, no drift between the two files.
LABEL_FROM_INSTALLER="$(bash "${ROOT_DIR}/scripts/install-watcher.sh" label)"
[ "$LABEL_FROM_INSTALLER" = "com.nhangen.obsidian-vaultkeeper" ] \
  || fail "installer label drifted: '$LABEL_FROM_INSTALLER'"
[ "$(keeper_label)" = "$LABEL_FROM_INSTALLER" ] \
  || fail "bootstrap label '$(keeper_label)' != installer label '$LABEL_FROM_INSTALLER'"

# --- keeper_scheduler_installed: macOS file-based check ---
FAKE_HOME="$WORK/home"; mkdir -p "$FAKE_HOME/Library/LaunchAgents"
if HOME="$FAKE_HOME" KEEPER_OS="Darwin" keeper_scheduler_installed; then
  fail "scheduler reported installed with no plist present"
fi
touch "$FAKE_HOME/Library/LaunchAgents/$(keeper_label).plist"
if ! HOME="$FAKE_HOME" KEEPER_OS="Darwin" keeper_scheduler_installed; then
  fail "scheduler reported absent when plist exists"
fi

# --- keeper_ensure_active: clean state seeds + installs exactly once ---
mk_config() {
  local cfg="$1"
  printf -- '---\nvault_path: %s\nauto_save: true\n---\n' "$2" > "$cfg"
}
mk_vault() {
  local v="$1"; mkdir -p "$v"
  printf -- '---\ntags: [a]\ntype: note\n---\nbody\n' > "$v/one.md"
  printf -- '---\ntags: [b]\ntype: note\n---\nbody\n' > "$v/two.md"
}

CFG="$WORK/obsidian.local.md"; VAULT="$WORK/vault"
mk_config "$CFG" "$VAULT"; mk_vault "$VAULT"
CALLS="$WORK/install-calls.log"; : > "$CALLS"
export VAULTKEEPER_INSTALL="$WORK/stub-install.sh"
cat > "$VAULTKEEPER_INSTALL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
EOF
chmod +x "$VAULTKEEPER_INSTALL"

FAKE_HOME2="$WORK/home2"; mkdir -p "$FAKE_HOME2/Library/LaunchAgents"
run_ensure() {
  HOME="$FAKE_HOME2" KEEPER_OS="Darwin" \
    keeper_ensure_active "$ROOT_DIR" "$CFG" "$VAULT" 900
}

run_ensure || fail "ensure_active returned non-zero on clean state"
grep -q '^frontmatter_required:' "$CFG" || fail "schema not seeded into config"
grep -q '^keeper_autostart:' "$CFG" || fail "keeper_autostart default not written"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = "1" ] || fail "expected exactly one install call, got $(cat "$CALLS")"
grep -q 'vaultkeeper-tick.sh' "$CALLS" || fail "install call missing tick path"

# Simulate the install having landed the plist, then re-run: must be a no-op.
touch "$FAKE_HOME2/Library/LaunchAgents/$(keeper_label).plist"
run_ensure || fail "ensure_active returned non-zero when already installed"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = "1" ] \
  || fail "ensure_active re-installed when already active (not idempotent): $(cat "$CALLS")"

# --- opt-out: keeper_autostart: false skips install entirely ---
CFG2="$WORK/optout.local.md"; VAULT2="$WORK/vault2"
printf -- '---\nvault_path: %s\nkeeper_autostart: false\n---\n' "$VAULT2" > "$CFG2"
mk_vault "$VAULT2"
CALLS2="$WORK/install-calls2.log"; : > "$CALLS2"
FAKE_HOME3="$WORK/home3"; mkdir -p "$FAKE_HOME3/Library/LaunchAgents"
VAULTKEEPER_INSTALL_BAK="$VAULTKEEPER_INSTALL"
export VAULTKEEPER_INSTALL="$WORK/stub-install2.sh"
cat > "$VAULTKEEPER_INSTALL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS2"
EOF
chmod +x "$VAULTKEEPER_INSTALL"
HOME="$FAKE_HOME3" KEEPER_OS="Darwin" \
  keeper_ensure_active "$ROOT_DIR" "$CFG2" "$VAULT2" 900 \
  || fail "ensure_active returned non-zero on opt-out config"
[ ! -s "$CALLS2" ] || fail "keeper_autostart:false still installed: $(cat "$CALLS2")"

# --- wiring: the Stop hook actually invokes the bootstrap ---
SAVE="${ROOT_DIR}/scripts/session-save.sh"
grep -q 'keeper-bootstrap.sh' "$SAVE" || fail "session-save.sh does not source keeper-bootstrap.sh"
grep -q 'keeper_ensure_active' "$SAVE" || fail "session-save.sh never calls keeper_ensure_active"

echo "PASS: keeper-bootstrap"
