#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/note-hash.sh"
. "$ROOT_DIR/scripts/lib/keeper-state.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/surfacing-command-failures-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
REAL_SORT="$(command -v sort)"; REAL_COMM="$(command -v comm)"
REAL_SED="$(command -v sed)"; REAL_MKTEMP="$(command -v mktemp)"
REAL_GREP="$(command -v grep)"
export REAL_SORT REAL_COMM REAL_SED REAL_MKTEMP REAL_GREP
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sort" <<'EOF'
#!/usr/bin/env bash
if [ "$FAULT" = sort ] && [ "$*" = -u ]; then
  input="$(cat)"
  if [[ "$input" == *$'GAP\tnew-gap.md'* ]]; then
    printf 'sort\n' >> "$INJECTED"
    exit 71
  fi
  printf '%s\n' "$input" | "$REAL_SORT" "$@"
  exit $?
fi
exec "$REAL_SORT" "$@"
EOF
cat > "$TMP/bin/comm" <<'EOF'
#!/usr/bin/env bash
if [ "$FAULT" = comm ]; then
  printf 'comm\n' >> "$INJECTED"
  exit 72
fi
exec "$REAL_COMM" "$@"
EOF
cat > "$TMP/bin/sed" <<'EOF'
#!/usr/bin/env bash
if { [ "$FAULT" = payload ] && [ "${1:-}" = $'s/\t/: /' ]; } ||
   { [ "$FAULT" = dedup ] && [ "${1:-}" = -n ]; }; then
  printf '%s\n' "$FAULT" >> "$INJECTED"
  exit 73
fi
exec "$REAL_SED" "$@"
EOF
cat > "$TMP/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$FAULT:$*" in payload:*kbscan*|dedup:*kbscan*|match:*kbscan*|extraction:*kbscan*) exit 74 ;; esac
exec "$REAL_MKTEMP" "$@"
EOF
cat > "$TMP/bin/grep" <<'EOF'
#!/usr/bin/env bash
if [ "$FAULT" = extraction ] && [ "${1:-}" = $'^QUARANTINE\t' ]; then
  # The digest uses this same filter before the receipt extraction.
  if [ ! -f "$INJECTED.digest" ]; then
    : > "$INJECTED.digest"
    exec "$REAL_GREP" "$@"
  fi
  printf 'extraction\n' >> "$INJECTED"
  printf 'QUARANTINE\tPARTIAL-EXTRACTION.md\n'
  exit 2
fi
if [ "$FAULT" = match ] && [ "${1:-}" = -qxF ]; then
  printf 'match\n' >> "$INJECTED"
  exit 2
fi
exec "$REAL_GREP" "$@"
EOF
chmod +x "$TMP/bin/"*

[ "$#" -gt 0 ] || set -- sort comm payload dedup match extraction
for fault_case in "$@"; do
    V="$TMP/$fault_case"; mkdir -p "$V/Inbox"
    printf -- '---\ntags: [x]\n---\nold\n' > "$V/old-gap.md"
    printf 'human pending content\n' > "$V/Pending.md"
    CFG="$TMP/$fault_case.local.md"
    printf 'vault_path: %s\nfrontmatter_required: tags type\nkeeper_host_priority: test-host\n' "$V" > "$CFG"
    OBSIDIAN_LOCAL_MD="$CFG" VAULTKEEPER_HOST=test-host \
      bash "$ROOT_DIR/scripts/vaultkeeper-tick.sh" >"$TMP/seed.out" 2>&1 \
      || fail "$fault_case: seed tick failed: $(cat "$TMP/seed.out")"
    SNAP="$(keeper_snapshot_file "$V")"
    cp "$SNAP" "$TMP/$fault_case.snapshot"
    cp "$V/Pending.md" "$TMP/$fault_case.pending"
    printf '123456\n' > "$(keeper_last_scan_file "$V")"
    rm -f "$(keeper_cache_dir "$V")/monitor.state"
    printf -- '---\ntags: [x]\n---\nnew\n' > "$V/new-gap.md"
    case "$fault_case" in
      payload|dedup|match|extraction) printf 'conflict\n' > "$V/Pending.sync-conflict-20261015-120000-FAULT.md" ;;
    esac
    OUT="$TMP/$fault_case.out"
    PATH="$TMP/bin:$PATH" FAULT="$fault_case" INJECTED="$TMP/$fault_case.injected" \
      OBSIDIAN_LOCAL_MD="$CFG" VAULTKEEPER_HOST=test-host \
      bash "$ROOT_DIR/scripts/vaultkeeper-tick.sh" >"$OUT" 2>&1 \
      || fail "$fault_case: tick aborted: $(cat "$OUT")"
    [ -s "$TMP/$fault_case.injected" ] || fail "$fault_case: injection never reached production"
    cmp -s "$SNAP" "$TMP/$fault_case.snapshot" || fail "$fault_case: snapshot advanced after command failure"
    cmp -s "$V/Pending.md" "$TMP/$fault_case.pending" || fail "$fault_case: Pending.md changed after command failure"
    [ "$(keeper_last_scan "$V")" = 123456 ] || fail "$fault_case: failed transition recorded last_scan"
    [ -f "$(keeper_cache_dir "$V")/monitor.state" ] || fail "$fault_case: command failure prevented monitoring"
    grep -q 'scan complete\|quarantine receipts appended' "$OUT" \
      && fail "$fault_case: tick falsely reported success: $(cat "$OUT")"
    case "$fault_case" in
      sort) diagnostic='cannot sort candidates' ;;
      comm) diagnostic='cannot compare snapshot' ;;
      payload) diagnostic='cannot format pending receipt' ;;
      dedup) diagnostic='cannot read pending receipts' ;;
      match) diagnostic='cannot match pending receipt' ;;
      extraction) diagnostic='failed to extract quarantine receipts' ;;
    esac
    grep -q "$diagnostic" "$OUT" || fail "$fault_case: missing command failure diagnostic: $(cat "$OUT")"
    [ -z "$(find "$V" -name '.Pending-*' -print)" ] || fail "$fault_case: failed append leaked a temp file"
    case "$fault_case" in
      sort|comm)
        OBSIDIAN_LOCAL_MD="$CFG" VAULTKEEPER_HOST=test-host \
          bash "$ROOT_DIR/scripts/vaultkeeper-tick.sh" >"$OUT" 2>&1 \
          || fail "$fault_case: healthy retry aborted: $(cat "$OUT")"
        grep -qF -- '- [ ] GAP: new-gap.md' "$V/Pending.md" \
          || fail "$fault_case: candidate was lost on healthy retry"
        ;;
      *)
        grep -q 'scan INCOMPLETE' "$OUT" || fail "$fault_case: original partial scan was not reported"
        grep -q '^quarantine_status=firing$' "$(keeper_cache_dir "$V")/monitor.state" \
          || fail "$fault_case: monitor did not observe the quarantined conflict"
        ;;
    esac
    printf 'PASS: surfacing command failure %s\n' "$fault_case"
done
