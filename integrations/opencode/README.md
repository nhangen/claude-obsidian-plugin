# Obsidian MCP for OpenCode

Connect OpenCode to Obsidian MCP for vault exploration, structured metadata inspection, and guarded writes.

## Prerequisites

- **OpenCode**: Any release supporting JSON-RPC Model Context Protocol (MCP) servers.
- **Node.js**: 22 or newer for Streamable HTTP read bridge / launchers; Node 20+ for stdio.
- **Python**: 3.10 or newer (for client bundle installation).

## Configuration (`opencode.json` / `opencode.jsonc`)

Add the `obsidian` and `obsidian-write` MCP servers to your OpenCode configuration:

```jsonc
{
  "$schema": "https://opencode.ai/schema/opencode.json",
  "mcp": {
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

## Scoped Host Authorization

Routine writes (`obsidian_keeper_save`, `obsidian_daily_append`) require host-level write policy to avoid constant interactive approval prompts. In `opencode.jsonc`:

```jsonc
{
  "permission": {
    "obsidian-write_*": "allow"
  }
}
```

This grants authorization specifically to the `obsidian-write` server's declared tools. The read server requires no special permissions beyond normal tool execution.

## Supported Workflows

- **Bounded Search**: Call `obsidian_find_notes` with `{ "query": "..." }` to find up to 5 matching note snippets.
- **Published Resources**: Read `obsidian://taxonomy`, `obsidian://daily/{date}`, `obsidian://librarian`, and `obsidian://pending`.
- **Commit Metadata**: Read sanitized git commit information via `obsidian_commit_meta`.
- **Guarded Note Writes**: Save notes with `obsidian_keeper_save` using an idempotency key.
- **Daily Append**: Append sections with `obsidian_daily_append`.
- **Prompts**: `ask_vault_librarian` and `summarize_session` provide read-only librarian guidance and session summary frontmatter.

The skill definition at `integrations/opencode/skills/obsidian-mcp/SKILL.md` can be placed in your OpenCode instructions or agent skills directory.

## Capture Status and Explicit Limits

> [!IMPORTANT]
> **OpenCode does not support automatic hook-based commit capture.**
> OpenCode currently lacks pinned turn-start lifecycle observers and git tool interception hooks. Do not attempt to configure automatic background capture hooks in OpenCode.
> Manual agent workflows (requesting the agent to search the vault, summarize notes, or save a note via MCP tools) are fully supported.
