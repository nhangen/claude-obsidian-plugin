# Obsidian MCP for OpenAI Codex

Connect OpenAI Codex CLI to Obsidian MCP for vault search, resource browsing, metadata extraction, and guarded writes.

## Prerequisites

- **Codex CLI**: 0.163.0 or newer for native hook-based capture; 0.135.0 or newer for skill-driven capture.
- **Node.js**: 22 or newer for Streamable HTTP read bridge / launchers; Node 20+ for stdio.
- **Python**: 3.11 or newer for native capture execution and metadata parsing.

## Connection Setup (`config.toml`)

In `~/.codex/config.toml` (or your isolated profile's `CODEX_HOME/config.toml`):

```toml
[mcp_servers.obsidian]
command = "/prefix/current/bin/obsidian-mcp-read"
default_tools_approval_mode = "auto"

[mcp_servers.obsidian.env]
OBSIDIAN_MCP_READ_ENDPOINT = "https://mcp.internal.example/mcp"
OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER = "env"
OBSIDIAN_MCP_READ_TOKEN_ENV = "MY_OBSIDIAN_READ_TOKEN"
MY_OBSIDIAN_READ_TOKEN = "JWT_TOKEN_WITH_VAULT_READ"

[mcp_servers."obsidian-write"]
command = "/prefix/current/bin/obsidian-mcp-write"
default_tools_approval_mode = "auto"

[mcp_servers."obsidian-write".env]
OBSIDIAN_MCP_WRITE_ENDPOINT = "https://mcp.internal.example/mcp"
OBSIDIAN_MCP_WRITE_CREDENTIAL_PROVIDER = "env"
OBSIDIAN_MCP_WRITE_TOKEN_ENV = "MY_OBSIDIAN_WRITE_TOKEN"
MY_OBSIDIAN_WRITE_TOKEN = "JWT_TOKEN_WITH_VAULT_WRITE"
```

## Scoped Host Authorization

Setting `default_tools_approval_mode = "auto"` inside `[mcp_servers."obsidian-write"]` authorizes the server's routine write tools (`obsidian_keeper_save` and `obsidian_daily_append`) without repetitive per-call confirmation prompts.

Other servers and unconfigured write tools retain standard approval prompts.

## Integration Modes

### 1. Isolated Native Capture (`obsidian-mcp-native`)

For automated session and commit capture without relying on the Claude plugin:

1. Create a fresh, disposable profile with the client installer's native tool:
   ```bash
   python3 /prefix/current/bin/obsidian-mcp-native create \
     --home ~/.codex/profiles/obsidian-capture \
     --project /path/to/clean/project \
     --folder "Vault/Folder/Hint" \
     --release-sha256 <bundle-release-sha256>
   ```
   Creation outputs a JSON result with `status: "created"` and `launch_command`:
   ```json
   {
     "status": "created",
     "home": "/path/to/.codex/profiles/obsidian-capture",
     "writer": "mcp",
     "scope": "isolated-profile",
     "launch_command": "python3 /prefix/current/bin/obsidian-mcp-native run --home /path/to/.codex/profiles/obsidian-capture",
     "release_id": "..."
   }
   ```
2. Launch Codex using the `launch_command` returned above (any additional options are forwarded directly to `codex`):
   ```bash
   python3 /prefix/current/bin/obsidian-mcp-native run --home ~/.codex/profiles/obsidian-capture
   ```
3. **Execution Flow**:
   - `UserPromptSubmit` supplies a turn-specific session save identity.
   - `PreToolUse` intercepts single `git commit` commands and rewrites them through a local bundled executor.
   - The executor executes git in an isolated subprocess, records the actual return code and reflog transition.
   - `PostToolUse` verifies the execution receipt and outputs a pending commit ID.
   - The agent prepares context and calls `obsidian_daily_append` via MCP.
   - Only a matching `status: "committed"` or `status: "skipped"` receipt confirms capture.
4. **Failure & Concurrency Handling**:
   - Replay skips duplicate appends idempotently.
   - Changed context conflicts locally and blocks automatic re-writes.
   - A pending event locks commit capture for that session; other sessions in the profile are denied until resolved.
   - Bounded recovery: `obsidian-mcp-native takeover` safely releases an interrupted owner's lock without reconstructing git history.

### 2. Skill-Driven Capture (`obsidian-mcp` skill)

If running Codex in an existing profile without native hooks:
- Register the servers as shown above.
- Add `integrations/codex/skills/obsidian-mcp/SKILL.md` to your skill path.
- The model invokes `obsidian_find_notes`, `obsidian_commit_meta`, and opt-in write tools on explicit user request.
- No hooks or background watchers run; writes are explicitly agent-invoked.

## Diagnostics & Troubleshooting

- Inspect status and pending events without vault access:
   ```bash
   /prefix/current/bin/obsidian-mcp-native status --home <profile> --session <key>
   ```
- Inspect original request payload for retry:
   ```bash
   /prefix/current/bin/obsidian-mcp-native request --home <profile> --session <key>
   ```
- Cleanly disable native capture:
  ```bash
  /prefix/current/bin/obsidian-mcp-native disable --home <profile>
  ```
  Disable removes owned profile config/hooks while retaining capture evidence.
