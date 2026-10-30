---
name: setup
description: Set up the Codex plugin's verified public runtime and guide separately authorized MCP connection registration through the Codex CLI. Runtime lifecycle previews by default; capture activation remains separate.
---

# Set up Obsidian for Codex

## Runtime lifecycle

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

Success establishes only runtime lifecycle state. `--apply` applies only that
lifecycle operation; it does not authorize or perform connection registration.
Do not follow disable/rollback with registration or silently enable a disabled
runtime. Connection setup below requires an enabled, verified runtime.

## Authorized connection follow-through

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
hooks, creates no native capture profile, changes no writer ownership, and never
falls back to local keeper. Automatic capture remains unchanged and requires a
separately verified handoff; do not invoke `obsidian-mcp-native create/attach`.
