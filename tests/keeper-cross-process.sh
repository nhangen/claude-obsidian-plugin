#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPER="$ROOT_DIR/scripts/keeper"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/keeper-cross-process-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
V="$TMP/vault"
mkdir -p "$V/.obsidian"
printf 'body\n' > "$TMP/body.md"

run_parallel_append() {
  local label="$1" out="$TMP/$1-results" caller round n=0
  local callers=(watcher hook stdio http)
  mkdir -p "$out"
  for round in $(seq 1 6); do
    for caller in "${callers[@]}"; do
      n=$(( n + 1 ))
      (
        bash "$KEEPER" append --vault "$V" --target "Daily/2026-09-22.md" \
          --section "## 12:00 — abc117" --body-file "$TMP/body.md" \
          --skip-if-hash abc117 --format json > "$out/$caller-$round.json"
      ) &
    done
  done
  wait
  [ "$(grep -l '"status":"committed"' "$out"/*.json | wc -l | tr -d ' ')" = 1 ] \
    || fail "$label append did not produce exactly one committed outcome"
  [ "$(grep -l '"status":"skipped"' "$out"/*.json | wc -l | tr -d ' ')" = 23 ] \
    || fail "$label append did not report every duplicate as skipped"
  [ "$(grep -c '^## 12:00 — abc117$' "$V/Daily/2026-09-22.md" | tr -d ' ')" = 1 ] \
    || fail "$label append wrote the idempotency key more than once"
}

run_parallel_append competing-processes

for n in $(seq 1 24); do
  bash -c '
    . "$1"
    . "$2"
    printf "QUARANTINE\twatcher-receipt\n" | surfacing_pending_append "$3"
  ' _ "$ROOT_DIR/scripts/lib/note-hash.sh" "$ROOT_DIR/scripts/lib/surfacing.sh" "$V" &
done
wait
[ "$(grep -cFx -- '- [ ] QUARANTINE: watcher-receipt' "$V/Pending.md")" = 1 ] \
  || fail "watcher dedup and append were not one cross-process critical section"

printf 'first complete note\n' > "$TMP/one.md"
printf 'second complete note\n' > "$TMP/two.md"
mkdir -p "$TMP/inserts"
set +e
bash "$KEEPER" insert --vault "$V" --target 'Notes/collision.md' \
  --body-file "$TMP/one.md" --format json > "$TMP/inserts/one.json" & p1=$!
bash "$KEEPER" insert --vault "$V" --target 'Notes/collision.md' \
  --body-file "$TMP/two.md" --format json > "$TMP/inserts/two.json" & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
set -e
[ "$r1" = 0 ] || [ "$r2" = 0 ] || fail "neither racing insert committed"
[ "$r1" = 3 ] || [ "$r2" = 3 ] || fail "losing insert was not an explicit conflict"
[ "$(grep -l '"status":"committed"' "$TMP/inserts/"*.json | wc -l | tr -d ' ')" = 1 ] \
  || fail "insert race did not return one committed outcome"
[ "$(grep -l '"status":"conflict"' "$TMP/inserts/"*.json | wc -l | tr -d ' ')" = 1 ] \
  || fail "insert race did not return one conflict outcome"
cmp -s "$V/Notes/collision.md" "$TMP/one.md" || cmp -s "$V/Notes/collision.md" "$TMP/two.md" \
  || fail "insert collision truncated or interleaved the note"

OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE" "$V/Safe"
ln -s "$OUTSIDE" "$V/Safe/escape"
ln -s "$OUTSIDE/final.md" "$V/Safe/final-link.md"
for target in '/absolute.md' '../traversal.md' $'Safe/new\nline.md' $'Safe/tab\tdelimiter.md' 'Safe/escape/gone.md' 'Safe/final-link.md'; do
  if bash "$KEEPER" append --vault "$V" --target "$target" --body-file "$TMP/body.md" --format json >/dev/null 2>&1; then
    fail "unsafe target was accepted: $target"
  fi
  if bash "$KEEPER" insert --vault "$V" --target "$target" --body-file "$TMP/body.md" --format json >/dev/null 2>&1; then
    fail "unsafe insert target was accepted: $target"
  fi
done
[ -z "$(find "$OUTSIDE" -mindepth 1 -print -quit)" ] || fail "symlink escape wrote outside the vault"

set +e
bash "$KEEPER" append --vault "$V" --target '../failed.md' \
  --body-file "$TMP/body.md" --format json > "$TMP/failed.json" 2>/dev/null
failed_rc=$?
set -e
[ "$failed_rc" = 1 ] || fail "rejected write did not exit 1"
grep -q '"status":"failed"' "$TMP/failed.json" || fail "rejected write omitted structured failed outcome"

bash "$KEEPER" append --vault "$V" --target 'Safe/-[] !#%&()+,;=@.md' \
  --section 'hostile filename' --body-file "$TMP/body.md" --format json >/dev/null \
  || fail "safe hostile filename was rejected"
bash "$KEEPER" insert --vault "$V" --target 'Safe/-[] !#%&()+,;=@-insert.md' \
  --body-file "$TMP/body.md" --format json >/dev/null \
  || fail "safe hostile insert filename was rejected"

for fault in after_note after_index before_index_state after_index_state before_daily after_daily; do
  target="Faults/$fault.md"
  set +e
  KEEPER_FAULT_INJECT="$fault" bash "$KEEPER" insert --vault "$V" --target "$target" \
    --body-file "$TMP/body.md" --title "$fault" --session-link-date 2026-09-22 \
    --format json > "$TMP/$fault.json"
  rc=$?
  set -e
  [ "$rc" = 2 ] || fail "$fault returned $rc instead of partial"
  grep -q '"status":"partial"' "$TMP/$fault.json" || fail "$fault reported false success"
  grep -q '"recovery":' "$TMP/$fault.json" || fail "$fault omitted recovery state"
  bash "$KEEPER" insert --vault "$V" --target "$target" --body-file "$TMP/body.md" \
    --title "$fault" --session-link-date 2026-09-22 --recover --format json > "$TMP/$fault-recover.json" \
    || fail "$fault was not recoverable"
  grep -q '"status":"committed"' "$TMP/$fault-recover.json" || fail "$fault recovery did not commit"
  grep -qF -- "- [[Faults/$fault]]" "$V/Faults/INDEX.md" \
    || fail "$fault recovery left INDEX incomplete"
  grep -qF -- "$fault.md" "$V/Faults/.INDEX.state" \
    || fail "$fault recovery left INDEX state incomplete"
  grep -qF -- "[[Faults/$fault]]" "$V/Daily/2026-09-22.md" \
    || fail "$fault recovery left the daily backlink incomplete"
done

echo "PASS: keeper-cross-process"
