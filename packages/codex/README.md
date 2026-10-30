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

Runtime lifecycle commands do not register MCP servers. After separately
authorized connection setup, the `setup` skill guides the existing Codex CLI to
register the verified public read/write launchers in the exact intended
`CODEX_HOME`. Its examples use existing private credential-file references or
macOS keychain identifiers, never raw tokens. The public runtime resolves them.

Both server names are inspected before any addition and rechecked immediately
before it. Matching registrations are reused; differing entries, inspection
failures, and concurrent changes stop setup. Inspection prints only presence or
a match verdict, never full registration JSON. These checks are not an atomic
create-only guarantee; stop when another configuration writer is active.

Existing approval policy is preserved. Routine-write host authorization is
separate and is not silently granted for new entries. Reconnect and verify
discovery plus a bounded read before calling the connection successful. No
credentials, native capture profiles, ownership handoff, hooks, or local keeper
fallback are installed by connection setup. Automatic capture stays unchanged.
The connection examples are smoke-checked with actual Codex CLI 0.162.1 and 0.164.0 in an
isolated HOME, CODEX_HOME, and working directory, using mock references without
calling credential providers.

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
