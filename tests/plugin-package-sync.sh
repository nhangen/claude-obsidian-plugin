#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q
for item in .agents/plugins/marketplace.json .claude-plugin hooks scripts packages; do
  mkdir -p "$(dirname "$item")"
  git -C "$ROOT" ls-files -z -- "$item" |
    while IFS= read -r -d '' file; do
      [ -f "$ROOT/$file" ] || continue
      mkdir -p "$(dirname "$file")"
      cp -p "$ROOT/$file" "$file"
    done
done
cp "$ROOT/scripts/sync-plugin-packages.py" scripts/
git add -A
sync() { python3 scripts/sync-plugin-packages.py "$@"; }
version() { python3 -c 'import json; print(json.load(open("packages/codex/.codex-plugin/plugin.json"))["version"])'; }
next() {
  local -a parts
  IFS=. read -r -a parts <<< "$1"
  printf '%s.%s.%s\n' "${parts[0]}" "${parts[1]}" "$((parts[2]+1))"
}

sync
sync --check
first="$(version)"
printf '\n' >> hooks/hooks.json
! sync --check || exit 1
sync
second="$(version)"
test "$second" = "$(next "$first")"
sync --check

printf '\n' >> packages/codex/hooks/hooks.json
! sync --check || exit 1
sync
third="$(version)"
test "$third" = "$(next "$second")"
sync --check

printf '\n' >> scripts/lib/capture-owner.py
! sync --check || exit 1
sync
fourth="$(version)"
test "$fourth" = "$(next "$third")"
cmp scripts/lib/capture-owner.py packages/codex/skills/commit-capture/scripts/lib/capture-owner.py
sync --check

printf '\n' >> packages/codex/skills/commit-capture/scripts/lib/capture-owner.py
! sync --check || exit 1
sync
test "$(version)" = "$fourth"
cmp scripts/lib/capture-owner.py packages/codex/skills/commit-capture/scripts/lib/capture-owner.py
sync --check
