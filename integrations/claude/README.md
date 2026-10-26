# Obsidian MCP for Claude Code

Connect Claude Code directly to Obsidian MCP over standard stdio or authenticated Streamable HTTP without requiring the Claude plugin or a local vault checkout on the client machine.

## Prerequisites

- **Claude Code CLI**: 0.2.29 or newer.
- **Node.js**: 22 or newer for Streamable HTTP read bridge / launchers; Node 20+ for stdio.
- **Python**: 3.10+ (if using the client installer or native capture utilities).

## Connection Setup

### 1. Stdio (Local Server)

When running the MCP server locally on the same machine where Claude Code runs:

```json
{
  "mcpServers": {
    "obsidian": {
      "command": "node",
      "args": ["/absolute/path/to/packages/mcp-server/dist/stdio.mjs"],
      "env": {
        "OBSIDIAN_LOCAL_MD": "/absolute/path/to/obsidian.local.md",
        "MCP_REPOSITORY_ROOTS": "/absolute/path/to/repositories"
      }
    }
  }
}
```

By default, the stdio server defaults to the read profile. To enable routine note saving and daily note appends without repetitive approval, add a write server:

```json
{
  "mcpServers": {
    "obsidian": {
      "command": "node",
      "args": ["/absolute/path/to/packages/mcp-server/dist/stdio.mjs"],
      "env": {
        "OBSIDIAN_LOCAL_MD": "/absolute/path/to/obsidian.local.md",
        "MCP_REPOSITORY_ROOTS": "/absolute/path/to/repositories"
      }
    },
    "obsidian-write": {
      "command": "node",
      "args": ["/absolute/path/to/packages/mcp-server/dist/stdio.mjs"],
      "env": {
        "OBSIDIAN_LOCAL_MD": "/absolute/path/to/obsidian.local.md",
        "MCP_STDIO_PROFILE": "write",
        "MCP_REPOSITORY_ROOTS": "/absolute/path/to/repositories"
      }
    }
  }
}
```

### 2. Streamable HTTP (Remote Server)

For remote server deployments (e.g., dedicated server, Tailscale tailnet), install the client bundle with `python3 bin/obsidian-mcp-client-install` and configure the launchers:

```json
{
  "mcpServers": {
    "obsidian": {
      "command": "/prefix/current/bin/obsidian-mcp-read",
      "env": {
        "OBSIDIAN_MCP_READ_URL": "https://mcp.internal.example/mcp",
        "OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER": "env",
        "OBSIDIAN_MCP_READ_TOKEN": "JWT_TOKEN_WITH_VAULT_READ"
      }
    },
    "obsidian-write": {
      "command": "/prefix/current/bin/obsidian-mcp-write",
      "env": {
        "OBSIDIAN_MCP_WRITE_URL": "https://mcp.internal.example/mcp",
        "OBSIDIAN_MCP_WRITE_CREDENTIAL_PROVIDER": "env",
        "OBSIDIAN_MCP_WRITE_TOKEN": "JWT_TOKEN_WITH_VAULT_WRITE"
      }
    }
  }
}
```

`OBSIDIAN_MCP_<PROFILE>_CREDENTIAL_PROVIDER` accepts `env`, `file`, or `keychain` (macOS). Tokens are passed in environment references directly to the child process and are never written to disk or logs.

## Scoped Host Authorization

Automatic MCP writes require scoped host policy rather than repetitive manual confirmation. In `~/.claude/settings.json` or project configuration:

```json
{
  "permissions": {
    "allow": [
      "mcp__obsidian-write__*"
    ]
  }
}
```

This rule permits `obsidian_keeper_save` and `obsidian_daily_append` under the authenticated write profile. Requests outside the MCP contract remain rejected.

## Workflows & Capabilities

| Workflow | Tool / Resource | Access | Description |
| --- | --- | --- | --- |
| Bounded read | `obsidian_find_notes` | Read | Scans vault notes for query; returns top 5 bounded snippets. |
| Resource read | `obsidian://*` | Read | Accesses published resources (`taxonomy`, `daily/{date}`, `librarian`, `pending`). |
| Commit metadata | `obsidian_commit_meta` | Read | Emits sanitized commit info for an allowlisted repository. |
| Guarded note save | `obsidian_keeper_save` | Write | Saves a structured note into an authorized taxonomy folder; requires `idempotency_key`. |
| Daily append | `obsidian_daily_append` | Write | Appends a section to the daily note or exact target note; supports `--skip-if-hash`. |
| Librarian prompt | `ask_vault_librarian` | Read | Generates read-only guidance from vault indexes without modifying files. |
| Session summary | `summarize_session` | Read | Generates client-side summary frontmatter; does not write to vault. |

## Automatic Capture vs. Standalone Usage

- The **Claude plugin** is one optional integration providing automatic session capture and git post-commit hooks within Claude Code sessions.
- In standalone client mode, Claude Code uses the MCP tools listed above directly or through the provided `integrations/claude/skills/obsidian-mcp/SKILL.md` skill.
- Automatic hook-based capture requires either the Claude plugin hooks or an explicit host execution event; silent fallback or guessed git histories are forbidden.

## Diagnostics & Limits

- **Errors**: Returned with stable structured error codes (`INVALID_INPUT`, `READ_FAILED`, `CONFLICT`, `PARTIAL`, `WRITE_FAILED`, `SUBPROCESS_TIMEOUT`).
- **Connection vs. Operation**: Server connection alone is not proof of write success. Inspect structured MCP receipts (`status: "committed"` or `status: "skipped"`).
- **Timeouts**: Individual subprocess timeouts are capped at 5000ms by default; HTTP request timeouts default to 30000ms.
