#!/usr/bin/env bash
# Exercises scripts/lib/resolve-config.sh — the version-independent config
# resolver. Reverting the resolver to a plugin-root-only lookup must fail this
# suite (cases 1 and 3 lock in stable-path precedence and version-independence).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${ROOT_DIR}/scripts/lib/resolve-config.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Each case runs in a hermetic environment: XDG_CONFIG_HOME points at a fresh
# temp dir (so the stable path is under our control) and OBSIDIAN_LOCAL_MD is
# cleared unless the case sets it.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/resolve-cfg-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

XDG="${SANDBOX}/xdg"
STABLE="${XDG}/claude-obsidian/obsidian.local.md"
PLUGIN_ROOT="${SANDBOX}/plugin"
OVERRIDE="${SANDBOX}/override.md"
mkdir -p "$(dirname "$STABLE")" "$PLUGIN_ROOT"

write_cfg() { printf -- '---\nvault_path: %s\n---\n' "$1" > "$2"; }
run() {
  # run [override] — resolve with our sandbox env; echoes resolved path, rc preserved.
  env -u OBSIDIAN_LOCAL_MD ${1:+OBSIDIAN_LOCAL_MD="$1"} \
    XDG_CONFIG_HOME="$XDG" bash "$RESOLVER" "$PLUGIN_ROOT"
}

PASS_COUNT=0

# ----- Case 1: stable path wins over plugin-root config -----
write_cfg "/stable/vault" "$STABLE"
write_cfg "/plugin/vault" "${PLUGIN_ROOT}/obsidian.local.md"
GOT=$(run) || fail "case1: resolver exited non-zero"
[ "$GOT" = "$STABLE" ] || fail "case1 (stable precedence): got '$GOT' want '$STABLE'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 2: only plugin-root config -> legacy fallback -----
rm -f "$STABLE"
GOT=$(run) || fail "case2: resolver exited non-zero"
[ "$GOT" = "${PLUGIN_ROOT}/obsidian.local.md" ] || fail "case2 (legacy fallback): got '$GOT'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 3: version-independence — empty plugin root, stable still resolves -----
write_cfg "/stable/vault" "$STABLE"
rm -f "${PLUGIN_ROOT}/obsidian.local.md"
GOT=$(run) || fail "case3: resolver exited non-zero"
[ "$GOT" = "$STABLE" ] || fail "case3 (version-independence): got '$GOT' want '$STABLE'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 4: OBSIDIAN_LOCAL_MD override wins over stable -----
write_cfg "/override/vault" "$OVERRIDE"
GOT=$(run "$OVERRIDE") || fail "case4: resolver exited non-zero"
[ "$GOT" = "$OVERRIDE" ] || fail "case4 (override): got '$GOT' want '$OVERRIDE'"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 5: nothing exists -> empty stdout, rc=1 -----
rm -f "$STABLE" "${PLUGIN_ROOT}/obsidian.local.md" "$OVERRIDE"
set +e
GOT=$(run)
RC=$?
set -e
[ -z "$GOT" ] || fail "case5 (none): expected empty, got '$GOT'"
[ "$RC" -eq 1 ] || fail "case5 (none): expected rc=1, got $RC"
PASS_COUNT=$((PASS_COUNT + 1))

# ----- Case 6: --stable prints canonical path regardless of existence -----
GOT=$(env XDG_CONFIG_HOME="$XDG" bash "$RESOLVER" --stable)
[ "$GOT" = "$STABLE" ] || fail "case6 (--stable): got '$GOT' want '$STABLE'"
PASS_COUNT=$((PASS_COUNT + 1))

printf '%d/6 cases passed\n' "$PASS_COUNT"
