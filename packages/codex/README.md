# Obsidian for Codex

This Codex package exposes `commit-capture` and `setup`. After a successful Git commit, `commit-capture` obtains sanitized metadata through its bundled `commit-meta.sh`, writes 3-8 conversation-context bullets through its bundled keeper, and prevents duplicate appends with `--skip-if-hash`.

The `setup` skill verifies, installs, or reuses the public client runtime as a
plugin implementation dependency. It resolves its helper from the installed
skill, authenticates fixed `nhangen/obsidian-mcp` `client-v0.3.0` release pins,
and delegates lifecycle to a freshly verified standalone public installer.
It needs Python 3.11+ on macOS, Linux, or WSL, without a private tools checkout.

Setup previews by default. Run the installed skill's
`scripts/bootstrap-runtime.py` with `--apply` to apply an authorized change.
`--prefix` selects the runtime prefix, and `--assets` selects an offline
directory containing the pinned installer, release metadata, and archive.
`--reinstall`, `--disable`, `--enable`, and `--rollback` also preview unless
`--apply` is present. Reinstallation verifies/reuses immutable content and
retains disabled state. Failed integrity or recovery checks stop setup.

Runtime setup does not register an MCP server, configure credentials, activate
a native Codex profile, transfer writer ownership, or install hooks. A
successful runtime install alone does not enable MCP or automatic capture.

Commit capture remains a legacy compatibility projection. Its keeper honors the shared
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
