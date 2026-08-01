# Codex Commit Capture

After every successful `git commit`, use the installed `obsidian:commit-capture` skill to save the conversation context to Obsidian. Current Codex CLI sessions load the skill but do not deliver this plugin's bundled `PreToolUse`/`PostToolUse` hooks, so this path is agent-invoked after the commit.

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

The Codex package contains one skill and no hooks, session watcher, or unrelated Claude-specific skills.

## Runtime flow

1. Trigger only after `git commit` exits successfully. Failed commits, dry runs, and non-commit Git commands do not qualify.
2. Resolve helpers relative to the installed skill and run its bundled `scripts/commit-meta.sh -C <repository>`.
3. If metadata resolution fails, report the error and stop. Never rebuild the record with `git rev-parse`, `git log`, or `git remote get-url`; the helper strips remote userinfo before it can reach a synced note.
4. Route exactly once:
   - `awesomemotive/*` -> `Awesome Motive/sessions/<date>-<repo>.md`
   - `altamira2/mtf-builder` -> `Altamira/mtf-builder/commits/<date>-mtf-builder-commits.md`
   - otherwise -> `Projects/Development/<org>/<repo>/<date>.md`
5. Build 3-8 dense context bullets from the conversation and append through the skill's bundled `scripts/keeper` with `--skip-if-hash`.
6. Report capture only after a zero exit. Distinguish an idempotent `append skipped` result from a new write, and report any non-zero keeper result as not captured.

`commit-meta.sh`, its parser/config dependencies, and `keeper` ship inside the Codex skill. The workflow does not depend on a Claude plugin installation or cache-path discovery.
