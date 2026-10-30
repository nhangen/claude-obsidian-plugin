---
name: setup
description: Verify, install, reuse, disable, enable, or roll back the public Obsidian client runtime when setting up the Codex plugin. Previews changes by default; does not register servers or activate capture profiles.
---

# Set up the public runtime

Resolve `scripts/bootstrap-runtime.py` relative to this installed `SKILL.md`.
Run it with Python 3.11+ on macOS, Linux, or WSL. Use that exact installed
helper path; do not search plugin caches or depend on a source checkout.

Run the helper without `--apply` first. It authenticates the three pinned
public `nhangen/obsidian-mcp` `client-v0.3.0` release assets, safely stages the
bundle, and asks the verified standalone public installer for a dry run.
Report the before/after runtime slots. If installation is already authorized,
continue with `--apply`; otherwise obtain approval for the displayed change.

The helper accepts `--prefix <directory>` and `--assets <offline-directory>`.
Offline mode requires `obsidian-mcp-client-install`,
`obsidian-mcp-client.release.json`, and `obsidian-mcp-client.tgz`; it makes no
network requests. Pins ship beside the helper and have no CLI override.

Use `--reinstall` to verify/reuse the pinned release. `--disable`, `--enable`,
and `--rollback` delegate lifecycle changes to the freshly authenticated
standalone installer. Every operation remains a preview until `--apply` is
present. Installation preserves an existing disabled state. If verification
or recovery checks refuse an operation, report the failure and stop; do not
delete state, run the installed prefix's installer, or bypass verification.

This sets up an implementation dependency of the plugin. Success establishes
only the runtime lifecycle state. Server registration, credentials, native
Codex profile activation, capture ownership/writer handoff, and hooks are
separate work and are not performed by this skill. Do not report MCP or
automatic capture as activated.
