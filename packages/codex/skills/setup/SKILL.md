---
name: setup
description: Set up Obsidian for Codex with a verified public runtime and bundled MCP connections, or preview separately authorized user-wide capture activation. Runtime, connection, capture and hook trust remain separate gates.
---

# Set up Obsidian for Codex

## Runtime lifecycle

Resolve `scripts/bootstrap-runtime.py` relative to this installed `SKILL.md`.
Run it with Python 3.11+ on macOS, Linux, or WSL. Use that exact installed
helper path; do not search plugin caches or depend on a source checkout.

Run the helper without `--apply` first. It authenticates the three pinned
public `nhangen/obsidian-mcp` `client-v0.3.1` release assets, safely stages the
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

Success establishes only runtime lifecycle state. `--apply` applies only that
lifecycle operation; it does not authorize or perform connection registration.
Do not follow disable/rollback with registration or silently enable a disabled
runtime. Connection setup below requires an enabled, verified runtime.

## Bundled connections (default)

The plugin contributes the canonical `obsidian` read and `obsidian-write` write
servers. Resolve `../../scripts/connection.py` relative to this installed
`SKILL.md`; do not use global wrapper names or search versioned caches.
Keep the exact intended nonempty absolute `CODEX_HOME` (default `$HOME/.codex`).
Connection configuration is user-wide for that home, not per workspace.

After the runtime is enabled and connection setup is authorized, preview:

```bash
python3 -I -B /absolute/installed/plugin/scripts/connection.py setup \
  --runtime-prefix /absolute/managed/runtime \
  --endpoint https://actual-server.example/mcp \
  --read-token-file /absolute/private/read-reference \
  --write-token-file /absolute/private/write-reference
```

Substitute the resolved installed helper and actual nonsecret references.
macOS keychain alternatives are `--read-keychain-service` plus
`--read-keychain-account`, and the corresponding `--write-*` flags. Do not read
tokens or invoke credential providers during setup. Files must already be
owned, single-link, 0400/0600; read/write references must be distinct. Unknown
providers, malformed configuration, or a differing existing connection record
stop setup rather than falling back. HTTP requires explicit `--allow-http`
for loopback, plus `--allow-tailnet-http` for tailnet addresses.

Add `--apply` only for the authorized config change. It writes nonsecret
references to `CODEX_HOME/obsidian-connection.json` (0600). Add
`--authorize-routine-tools` only when scoped routine read/write approval was
explicitly authorized. This adds `default_tools_approval_mode = "auto"` under
`plugins."obsidian@nhangen-codex-plugins".mcp_servers.<canonical-server>` only
for servers without global registrations and without conflicting plugin
policy. It refuses to relax existing disabled, prompt, or tool-filter policy;
profile-specific policy needs separate review. Without this flag, approvals
remain unchanged. Stop competing config writers before apply; files are
individually atomic, not a transaction across both config files. An interrupted
apply can leave connection config without the requested approval change;
report failure and re-preview rather than claiming completion.

Global registrations, including disabled ones, win over plugin declarations.
Do not remove or replace them to make the bundled connection win. Existing
host/project/managed restrictions still apply. Setup neither changes capture
ownership nor activates profiles or grants hook trust. No local keeper fallback
is authorized when MCP owns writes.

Reconnect and verify actual discovery plus a bounded read before reporting a
working connection. Use a supported host reconnect/reload if available; do not
invent a shell RPC or bypass the UI/trust boundary. CLI 0.166.0 fixture coverage
includes schema-supported `config/mcpServer/reload` with null parameters on an
already-started fixture chat and one configured home shared across two workspace
roots. A separate CLI fixture starts with a package lacking declarations, then
covers supported `plugin/install` of a local candidate and setup/reload on the
same chat. These fixtures neither publish a version nor update any user's
installed cache, and do not establish that the desktop UI exposes the same
refresh. If the host cannot reload, a fresh chat after updating plugin/config is a
fallback, not proof that the original existing chat is fixed.
Startup rechecks the live prefix's current/disabled state,
pending transitions, and fixed release pins using the authenticated verifier.
It never installs, enables, repairs, or selects a retained capture binding.
CLI 0.166.0 legacy MCP args do not expand `${PLUGIN_ROOT}`: declarations use
plugin-rooted `cwd: "."` with a relative helper path, verified by the real loader.

## Advanced: separately authorized global registrations

Use this path only when global registration is explicitly wanted instead of
the bundled connection; it takes precedence over bundled declarations. Do not
run it automatically after bundled setup.

Use the existing Codex CLI (stdio `mcp add --env KEY=VALUE`, `mcp list --json`,
and `mcp get --json`; smoke-checked with 0.162.1 and 0.164.0). No runtime capture command,
new configuration editor, local vault, or source checkout is needed. Only
proceed when connection registration itself is authorized. Otherwise show the
secret-free plan without running `add`.

Keep the exact intended `CODEX_HOME` for every inspection, addition, and
reconnect. If already set, preserve it; reject an empty value. If unset,
resolve it to `$HOME/.codex` after validating nonempty HOME. Set and export that
absolute path explicitly for these commands; do not switch profiles or cwd
mid-setup. Preserve project/managed policy and stop if effective configuration
cannot be determined.

Set and export `OBSIDIAN_CLIENT` to the verified runtime's absolute `current`
directory and `OBSIDIAN_ENDPOINT` to the actual HTTPS endpoint, without
userinfo, query, fragment, or embedded credentials. For this slice, stop on
HTTP endpoints rather than changing transport policy. Obtain references to
existing owned private 0400/0600 credential files, or existing macOS keychain
service/account names. Never read credentials during registration, ask for
tokens in chat, pass raw token values through `--env`, or use shell substitutions
that fetch a credential. The public launchers resolve credentials when connected.

Inspect both exact names before adding either. This prints only their presence;
all CLI JSON stays inside the local filter. A failed command, invalid JSON,
duplicate name, or unknown result is an inspection failure, never absence.
Never run unfiltered `list/get`, echo their JSON, or include raw diagnostics in
chat or logs.

<!-- connection-inventory -->
```bash
python3 - <<'PY'
import json, subprocess, sys
try:
    result = subprocess.run(["codex", "mcp", "list", "--json"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15, check=True)
    rows = json.loads(result.stdout)
    if not isinstance(rows, list) or any(not isinstance(r, dict) or not isinstance(r.get("name"), str) for r in rows):
        raise ValueError()
    names = [r["name"] for r in rows]
    if len(names) != len(set(names)):
        raise ValueError()
    print(json.dumps({n: "present" if n in names else "absent" for n in ("obsidian", "obsidian-write")}))
except Exception:
    print("INSPECTION_FAILED")
    sys.exit(64)
PY
```

For each name, set and export the following secret-free plan variables:

| Name (`OBSIDIAN_CONNECTION_NAME`) | Profile (`OBSIDIAN_CONNECTION_PROFILE`) | Launcher (`OBSIDIAN_CONNECTION_LAUNCHER`) |
| --- | --- | --- |
| `obsidian` | `READ` | `read` |
| `obsidian-write` | `WRITE` | `write` |

Set `OBSIDIAN_CONNECTION_PROVIDER=file` and `OBSIDIAN_CONNECTION_TOKEN_FILE` to
the absolute existing private file for that profile. On macOS, alternatively set
provider `keychain` and `OBSIDIAN_CONNECTION_KEYCHAIN_SERVICE` and
`OBSIDIAN_CONNECTION_KEYCHAIN_ACCOUNT` to existing identifiers. Use separately
scoped read/write references. Do not create credentials or invoke providers.

For every present name, compare its transport, launcher, arguments, credential
references, forwarding, and cwd locally with the plan. This emits only a verdict;
existing approval policy is deliberately neither printed nor changed.

<!-- connection-inspect -->
```bash
python3 - <<'PY'
import json, os, subprocess, sys
try:
    e = os.environ
    name, profile, launcher = (e["OBSIDIAN_CONNECTION_" + k] for k in ("NAME", "PROFILE", "LAUNCHER"))
    if (name, profile, launcher) not in (("obsidian", "READ", "read"), ("obsidian-write", "WRITE", "write")):
        raise ValueError()
    prefix = "OBSIDIAN_MCP_" + profile
    provider = e["OBSIDIAN_CONNECTION_PROVIDER"]
    expected = {prefix + "_ENDPOINT": e["OBSIDIAN_ENDPOINT"], prefix + "_CREDENTIAL_PROVIDER": provider}
    if provider == "file":
        expected[prefix + "_TOKEN_FILE"] = e["OBSIDIAN_CONNECTION_TOKEN_FILE"]
    elif provider == "keychain":
        for key in ("SERVICE", "ACCOUNT"):
            expected[prefix + "_KEYCHAIN_" + key] = e["OBSIDIAN_CONNECTION_KEYCHAIN_" + key]
    else:
        raise ValueError()
    result = subprocess.run(["codex", "mcp", "get", name, "--json"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15, check=True)
    value = json.loads(result.stdout)
    t = value["transport"]
    matches = (value["enabled"] is True and t["type"] == "stdio"
        and t["command"] == e["OBSIDIAN_CLIENT"] + "/bin/obsidian-mcp-" + launcher
        and not t.get("args") and t.get("env") == expected
        and not t.get("env_vars") and t.get("cwd") is None)
    print("MATCH" if matches else "CONFLICT")
except Exception:
    print("INSPECTION_FAILED")
    sys.exit(64)
PY
```

Reuse `MATCH` without calling `add`. Stop the entire setup on `CONFLICT` or
`INSPECTION_FAILED` before any addition; do not remove, overwrite, rename around,
or silently enable an existing registration. Check both names even if the first
is absent. Re-run inventory and inspection immediately before each addition;
stop on any concurrent change. These CLI checks are not an atomic create-only
guarantee. If another configuration writer is active or state is ambiguous,
stop instead of claiming overwrite protection.

After both initial checks pass, preview the command for each absent name. Run
only the appropriate provider example below for that name after its immediate
recheck. CLI errors remain private; report an incomplete registration and
inspect again rather than inferring success.

<!-- connection-add-file -->
```bash
codex mcp add "$OBSIDIAN_CONNECTION_NAME" \
  --env "OBSIDIAN_MCP_${OBSIDIAN_CONNECTION_PROFILE}_ENDPOINT=$OBSIDIAN_ENDPOINT" \
  --env "OBSIDIAN_MCP_${OBSIDIAN_CONNECTION_PROFILE}_CREDENTIAL_PROVIDER=file" \
  --env "OBSIDIAN_MCP_${OBSIDIAN_CONNECTION_PROFILE}_TOKEN_FILE=$OBSIDIAN_CONNECTION_TOKEN_FILE" \
  -- "$OBSIDIAN_CLIENT/bin/obsidian-mcp-$OBSIDIAN_CONNECTION_LAUNCHER" >/dev/null 2>&1
```

<!-- connection-add-keychain -->
```bash
codex mcp add "$OBSIDIAN_CONNECTION_NAME" \
  --env "OBSIDIAN_MCP_${OBSIDIAN_CONNECTION_PROFILE}_ENDPOINT=$OBSIDIAN_ENDPOINT" \
  --env "OBSIDIAN_MCP_${OBSIDIAN_CONNECTION_PROFILE}_CREDENTIAL_PROVIDER=keychain" \
  --env "OBSIDIAN_MCP_${OBSIDIAN_CONNECTION_PROFILE}_KEYCHAIN_SERVICE=$OBSIDIAN_CONNECTION_KEYCHAIN_SERVICE" \
  --env "OBSIDIAN_MCP_${OBSIDIAN_CONNECTION_PROFILE}_KEYCHAIN_ACCOUNT=$OBSIDIAN_CONNECTION_KEYCHAIN_ACCOUNT" \
  -- "$OBSIDIAN_CLIENT/bin/obsidian-mcp-$OBSIDIAN_CONNECTION_LAUNCHER" >/dev/null 2>&1
```

Inspect each addition and finally both names; require `MATCH`. If only one
addition succeeded, report partial registration, keep it, and resume with the
same plan and both-name checks. Never remove a successful entry to roll back.
Preserve all existing approval policy. New entries need separate scoped host
authorization for routine writes if that policy is not already present; do not
silently grant auto approval, use `-c` overrides to manufacture it, or describe
repeated per-write approval as that authorization.

Reconnect the intended host and verify discovery plus a bounded read before
claiming connection success. Registration is not a connection or write receipt.
Do not make a verification write unless requested. Connection setup installs no
native capture profile, changes no writer ownership, and never falls back to
local keeper. The package's native hooks remain dormant. Connection registration
alone does not authorize the separate capture handoff below; do not invoke
`obsidian-mcp-native create/attach` as part of connection setup.

## Separate user-wide capture activation

Resolve `../../scripts/capture.py` relative to this installed skill directory.
Use that installed helper with Python 3.11+, not a source checkout or a searched
cache path. Preserve the intended canonical `CODEX_HOME` throughout.

Inspect `codex-status` first. A missing record is dormant, not evidence of a
working connection or capture. Keep existing Claude ownership and profiles;
Codex has a separate admission record and does not need workspace enrollment.

The selected public runtime must advertise attached user-wide Codex capture and
native turn identity. The published bootstrap pin remains `client-v0.3.1`, which
does not support this new capability. Do not fabricate a release pin, execute
an unverified candidate, silently select an isolated profile, or call source
fixtures a published installation. Stop with an unsupported-capability result
until an independently authenticated compatible bundle is available.

For an authorized compatible bundle, obtain its release-metadata SHA-256 from
the trusted distribution, not from the candidate as its own authority. Preview:

```bash
python3 "<installed plugin>/scripts/capture.py" codex-activate \
  --codex-home "<intended canonical CODEX_HOME>" \
  --bundle "<verified compatible runtime release>" \
  --release-sha256 "<externally pinned release metadata SHA-256>" \
  --profile "<new private capture profile>" --create-profile \
  --folder "<authorized vault-relative folder>" --daily-folder "Daily"
```

Omit `--create-profile` to select an existing verified attached user-wide Codex
profile. For creation, select an existing server-authorized destination once;
defaults are `Sessions` and `Daily`, not proof those folders are allowed by the
server. Never use the actual Codex home as the capture profile. Preview must
not write state. Profile creation and admission changes require separate capture
authorization; runtime installation or MCP registration is not that approval.

Initial adoption refuses a profile whose interpreter differs from the running
trusted launcher. Do not execute an interpreter path read from an untrusted
profile as a workaround. Existing registered profiles retain their pinned launcher.

Before apply, stop older Codex sessions and cached writers, upgrade their guards,
inspect legacy history, and resolve pending captures through their original
recovery route. Do not delete or reclassify evidence to obtain a clear drain.
Only after those checks and explicit handoff authorization, rerun the same plan
with `--apply --verification legacy-writers-stopped-and-history-inspected`.
The attestation is a prerequisite, not proof that the checks actually happened.

Global disabled or draining ownership blocks both hosts. A failed handoff can
leave Codex admission draining; inspect it, resolve pending evidence and reapply
the same verified plan. Do not resume the legacy keeper or alter Claude's owner
to recover Codex. The helper verifies the runtime locally before native calls
and must not resolve credentials or change existing MCP approval policy.

Plugin delivery remains subject to Codex's normal hook-review flow. Direct the
user to review the installed definitions with `/hooks`; do not approve them or
edit the trust store for the user. A selected plugin/managed delivery gate
prevents double delegation, but administrator-managed activation is refused
until a validated administrator installation exists. This setup does not
install `requirements.toml`, force hooks on or suppress unrelated hooks.

`codex-disable` previews by default; authorized `--apply` requires the same
verification flag and a clear drain. It preserves disabled admission and
retained profiles, never restores legacy automatically or deletes capture
history. Verify actual native events, matching write receipts and a quiescent
drain separately before claiming installed-host capture success.
