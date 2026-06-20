#!/usr/bin/env bash
# run-all.sh — run every tests/*.sh (except this file); fail if any fails.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp "${TMPDIR:-/tmp}/vk-test.XXXXXX")" || exit 1
trap 'rm -f "$TMP"' EXIT
fails=0
for t in "$ROOT_DIR"/*.sh; do
  [ "$(basename "$t")" = "run-all.sh" ] && continue
  if bash "$t" >"$TMP" 2>&1; then
    echo "ok   $(basename "$t")"
  else
    echo "FAIL $(basename "$t")"; cat "$TMP"; fails=$(( fails + 1 ))
  fi
done
[ "$fails" -eq 0 ] || { echo "$fails suite(s) failed"; exit 1; }
echo "ALL PASS"
