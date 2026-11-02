# Codex Commit Capture

The installed `obsidian:commit-capture` skill is the guarded legacy route after a
successful Git commit. The package also contains setup and dormant native hooks.
An explicitly activated public Codex capture profile owns its native session and
commit flow; do not invoke the legacy route for those events. See the
[package activation contract](../../packages/codex/README.md#native-capture-activation).

## Install

```bash
codex plugin marketplace add nhangen/claude-obsidian-plugin
codex plugin add obsidian@nhangen-codex-plugins
```

Start a new session. Configure the vault through `$OBSIDIAN_LOCAL_MD` or `${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`:

```yaml
---
vault_path: /absolute/path/to/your/vault
---
```

Installing the package does not activate capture or trust its hooks. Legacy
local capture needs the vault configuration above; MCP capture does not need a
client-side vault mount. Claude's watcher and unrelated skills are not installed.

## Runtime flow

1. Before metadata, inspect global ownership with the installed skill's
   `scripts/lib/capture-owner.py status` and Codex admission with the installed
   plugin's `scripts/capture.py codex-status`, preserving the intended
   `CODEX_HOME`. Continue only for stable global legacy ownership and dormant
   Codex status. Existing activation, disabled/draining state or inspection
   failure never authorizes legacy fallback. Then require a successful Git
   commit; failed commits, dry runs and non-commit commands do not qualify.
2. Resolve helpers relative to the installed skill and run its bundled `scripts/commit-meta.sh -C <repository>`.
3. If metadata resolution fails, report the error and stop. Never rebuild the record with `git rev-parse`, `git log`, or `git remote get-url`; the helper strips remote userinfo before it can reach a synced note.
4. Route exactly once:
   - `awesomemotive/*` -> `Awesome Motive/sessions/<date>-<repo>.md`
   - `altamira2/mtf-builder` -> `Altamira/mtf-builder/commits/<date>-mtf-builder-commits.md`
   - otherwise -> `Projects/Development/<org>/<repo>/<date>.md`
5. Build 3-8 dense context bullets from the conversation and append through the skill's bundled `scripts/keeper` with `--skip-if-hash`.
6. Report capture only after a zero exit. Distinguish an idempotent `append skipped` result from a new write, and report any non-zero keeper result as not captured.

`commit-meta.sh`, its parser/config dependencies, and `keeper` ship inside the Codex skill. The workflow does not depend on a Claude plugin installation or cache-path discovery.
