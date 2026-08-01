# Obsidian Commit Capture for Codex

This Codex package exposes one skill: `commit-capture`. After a successful Git commit, it obtains sanitized metadata through its bundled `commit-meta.sh`, writes 3-8 conversation-context bullets through its bundled keeper, and prevents duplicate appends with `--skip-if-hash`.

## Install

```bash
codex plugin marketplace add nhangen/claude-obsidian-plugin
codex plugin add obsidian@nhangen-codex-plugins
```

Configure `vault_path` in `$OBSIDIAN_LOCAL_MD` or `${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`, then start a new Codex session.

Codex CLI 0.135.0 did not execute this plugin's bundled tool hooks in a forward test, so the package intentionally contains no hooks. The skill is invoked by the agent after a successful commit. It does not depend on a Claude plugin installation or a versioned cache path.
