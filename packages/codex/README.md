# Obsidian for Codex

This Codex package exposes `commit-capture`, `setup`, and dormant native capture
hooks. The legacy skill obtains sanitized commit metadata and writes conversation
context through its guarded keeper. Native capture uses a separately activated,
verified public runtime; installing the plugin alone does not activate it.

The `setup` skill verifies, installs, or reuses the public client runtime as a
plugin implementation dependency. It resolves its helper from the installed
skill, authenticates fixed `nhangen/obsidian-mcp` `client-v0.3.1` release pins,
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

The legacy commit skill's keeper honors shared and Codex-specific admission and
refuses local writes under MCP, disabled or draining ownership. Connection setup
does not activate capture or translate Claude profiles into Codex profiles. The server uses the
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

For legacy local capture, configure `vault_path` in `$OBSIDIAN_LOCAL_MD` or
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-obsidian/obsidian.local.md`.
For remote capture, use `setup` for runtime and connection setup, then follow the
separate activation contract below. No client-side vault mount is required.

## Native capture activation

Activation is once per canonical `CODEX_HOME`, not per workspace. The private
record also recognizes physical home aliases, including case aliases on
case-insensitive filesystems; ambiguous or corrupt inventory closes admission.
The public runtime must advertise attached user-wide Codex capture, native turn identities,
and the required recovery operations. Its new attached-profile capability was
merged in public source `f511884950777179de8e5bc47a2a5dd2bca52b7c`.
The published bootstrap remains pinned to `client-v0.3.1`, which does not provide
that capability. Source support is not a newer published release: activation
must refuse an unsupported runtime, not silently substitute an isolated profile.

An explicitly supplied release-metadata SHA-256 is the trust input. The plugin
authenticates its vendored standalone verifier against the published 0.3.1
installer pin, then verifies the selected runtime before executing capabilities,
profile operations or hooks. Installed releases and standalone bundles retain
their respective inventory checks. Runtime verification is local; hooks do not
download dependencies or obtain credentials.

Generated commit and recovery commands re-enter the packaged guard. It checks
the selected profile, delivery, ownership generations and runtime integrity at
execution time, holding admission through managed execution and initial
process-group cleanup. This is not an OS sandbox: independently detached user
Git-hook daemons can outlive that group, but Git does not inherit the capture
lease. Unleased capture re-entry must reacquire admission. Keep generated
commands intact; replacing them with a direct runtime invocation bypasses this guard.

The private Codex record selects a single delivery source. Plugin hooks and the
future managed adapter share admission; an unselected adapter does not delegate.
Administrator-managed activation is refused until a validated administrator
installation exists. This source change does not install system policy or make
plugin hooks automatically trusted. Codex requires review of non-managed hook
definitions and runs matching sources concurrently; see the
[official hook contract](https://learn.chatgpt.com/docs/hooks).

Before an authorized handoff, stop older Codex sessions and cached writers,
upgrade their guards, and inspect retained history. Preview is read-only; apply
requires explicit attestation and checks both previous and selected profile
drains under exclusive admission. Claude's owner and profile mappings remain
unchanged. Global disabled/draining ownership closes both hosts, and global
handoff includes retained Codex profiles in its drain inventory.

Missing activation leaves hooks dormant. Invalid, disabled, draining or
unavailable activated state never restores the legacy keeper. Interrupted
transitions preserve closed admission and pending evidence; recovery must
reverify and drain before reopening. Disabling capture retains the record and
profile evidence rather than deleting them or enabling legacy capture.

## Source verification

The new activation fixture suite requires `OBSIDIAN_PUBLIC_CLIENT_SOURCE` to
point to a checkout at the exact public source revision above. It packs that
source into a temporary bundle and invokes the installed-package adapters in
disposable homes with mock MCP receipts. CI supplies the pinned public checkout;
a missing dependency is a test failure, not a skipped acceptance check. These
fixtures do not establish real-provider capture, installed-host trust or managed
deployment acceptance.

```bash
OBSIDIAN_PUBLIC_CLIENT_SOURCE=/path/to/pinned/obsidian-mcp \
  bash tests/codex-capture-activation.sh
OBSIDIAN_PUBLIC_CLIENT_SOURCE=/path/to/pinned/obsidian-mcp \
  bash tests/run-all.sh
```
