---
name: reorganize
description: Reorganizes the Obsidian vault or a specific project. Triggers on phrases like "reorganize my vault", "clean up obsidian", "move X to Y in obsidian", "reorganize my notes", "restructure my projects", "organize the vault". Launches the vault-organizer subagent for deep analysis and execution.
version: 1.0.0
---

# Reorganize Vault

First run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/capture-owner.py" status`.
This is an explicit local-maintenance compatibility operation, not MCP parity.
Run the local workflow only for stable legacy ownership. With MCP, disabled,
draining, or unreadable ownership, stop; public MCP does not expose moves or a
filesystem reorganization transaction. Never bypass the owner with direct file
tools or enable a second writer.

Analyzes and reorganizes vault content. Always proposes a plan before touching any files.

## Resolve the Local Vault

MCP-only clients must not run local filesystem reorganization or install a
watcher. Use `packages/mcp-server/README.md` for the thin-client connection;
reorganization requires a separately approved operation on the vault host.

Run the following in Bash before analysis. Missing config, vault path, or taxonomy
is a configuration fault: report it and stop, without scanning a fallback path.

```bash
set -euo pipefail
: "${CLAUDE_PLUGIN_ROOT:?plugin root required}"
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-config.sh"
CONFIG="$(resolve_obsidian_config "$CLAUDE_PLUGIN_ROOT")" || exit 1
export OBSIDIAN_LOCAL_MD="$CONFIG"
VAULT="$(obsidian_config_value vault_path)" || exit 1
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 1
VAULT="$(cd "$VAULT" && pwd -P)" || exit 1
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/allowlist-validate.sh"
ALLOWED_FOLDERS="$(allowlist_list "$CONFIG")" || exit 1
[ -n "$ALLOWED_FOLDERS" ] || exit 1
```

Use `$VAULT` and the actual taxonomy/routing rules from `$CONFIG` throughout.
The organizer receives the resolved config, vault, scope, and proposed plan.

## Steps

1. **Scope** — is this full vault or a specific folder? Clarify if ambiguous.
2. **Analyze** — get the configured vault tree: `find "$VAULT" -type f -name "*.md" -not -path "*/.obsidian/*" | sort`. For a scoped request, inspect only the approved existing folder under `$VAULT`; reject traversal, symlinks escaping the vault, and paths outside the taxonomy.
3. **Identify issues:**
   - Orphaned notes (no inbound links, not in a project folder)
   - Misplaced files (wrong domain folder)
   - Duplicate/near-duplicate filenames
   - Empty folders
4. **Propose reorganization plan** — list every move/rename as `from → to` using vault-relative paths and include affected wikilinks. Validate each source and destination with `allowlist_validate "<path>" "$CONFIG"`. Include an existing allowed folder alongside the approved scoped target as the rollback location; do not invent a new root folder. For a full-vault request, choose one existing allowed folder and name it explicitly in the plan. Refuse overwrites and moves outside the vault.
5. **Wait for user approval** — do NOT move anything until confirmed
6. **Save rollback manifest** through the keeper using the payload below BEFORE executing. Validate its target and verify the keeper's committed result; on failure, stop before any move.
7. **Execute moves** — use approved Bash `mv` commands only, rechecking containment and destination absence before each move. Stop on failure and record which moves completed; rollback uses the inverse completed moves, never an assumed all-or-nothing result.
8. **Confirm** — show final structure diff

## Rollback Manifest Payload

Replace `<approved-existing-folder>` with the folder agreed in the plan and
`<run-id>` with a unique suffix. Do not overwrite an earlier manifest. Validate
the full target with `allowlist_validate` before submitting this exact payload
shape to `obsidian:keeper-save`:

```text
op: insert
resolved: true
target: <approved-existing-folder>/vault-reorg-<YYYY-MM-DD>-<run-id>.md
title: vault-reorg-<YYYY-MM-DD>-<run-id>
---
---
date: <YYYY-MM-DD>
tags: [vault-reorg, rollback]
---

# Vault Reorg - <YYYY-MM-DD>

## Approved Moves

| From | To |
|------|----|
| old/path.md | new/path.md |

## Rollback

Reverse each completed move from To to From in reverse execution order.
Refuse to overwrite an existing From path; report a conflict instead.
```

After execution, append the completed move list and any failure to the same
manifest through the keeper. Keep `.obsidian/` untouched and preserve explicit
approval before every reorganization plan is executed.
