# Obsidian Commit Capture for Codex

This Codex package exposes one skill: `commit-capture`. After a successful Git commit, it obtains sanitized metadata through its bundled `commit-meta.sh`, writes 3-8 conversation-context bullets through its bundled keeper, and prevents duplicate appends with `--skip-if-hash`.

This remains a legacy compatibility projection. Its keeper honors the shared
host-local capture owner and refuses local writes under MCP, disabled or
draining ownership. It does not infer MCP activation from connection setup or
translate Claude plugin profiles into Codex profiles. MCP capture requires the
public client's separately verified native Codex profile. The server uses the
unguarded keeper primitive on the authoritative vault host, not this client
entry point.

The guarded entry point requires Bash and Python 3.11+ with POSIX `fcntl` on
macOS, Linux or WSL. Install these before upgrading; native Windows Python and a
missing ownership module fail closed. The bundled `keeper-core` is the shared
primitive, not an alternative client entry point for bypassing ownership.

## Install

```bash
codex plugin marketplace add nhangen/claude-obsidian-plugin
codex plugin add obsidian@nhangen-codex-plugins
```

Configure `vault_path` in `$OBSIDIAN_LOCAL_MD` or `${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`, then start a new Codex session.

Codex CLI 0.135.0 did not execute this plugin's bundled tool hooks in a forward test, so the package intentionally contains no hooks. The skill is invoked by the agent after a successful commit. It does not depend on a Claude plugin installation or a versioned cache path.
