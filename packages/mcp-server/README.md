# MCP server

This package is the isolated MCP adapter for `claude-obsidian-plugin`.
It runs over stdio or authenticated Streamable HTTP and exposes the read-only `obsidian_find_notes` and
`obsidian_commit_meta` tools plus bounded read-only resources for taxonomy,
daily notes, the librarian index, and pending items. The existing root plugin,
hooks, commands, and keeper remain unchanged.

```bash
npm ci
npm test
npm start
```

Authenticated Streamable HTTP uses stateful sessions at `/mcp` for the
compatibility revision `2025-11-25`:

```bash
MCP_HTTP_JWT_SECRET='<at least 32 bytes>' \
MCP_HTTP_JWT_ISSUER='https://issuer.example' \
MCP_HTTP_JWT_AUDIENCE='claude-obsidian' \
MCP_HTTP_ALLOWED_HOSTS='127.0.0.1,localhost' \
MCP_HTTP_ALLOWED_ORIGINS='https://client.example' \
npm run start:http
```

The HTTP server binds `127.0.0.1:3000` by default. Set `MCP_HTTP_BIND` and
`MCP_HTTP_PORT` explicitly when needed. Remote deployments must terminate TLS
in a trusted reverse proxy and restrict network access to the configured bind
address. Every request requires an HS256 bearer JWT with the exact configured
issuer and audience, a future `exp`, and either `vault:read` or `repo:read`.
Vault tools and resources require `vault:read`; repository metadata requires
`repo:read`. Query strings are rejected, so credentials cannot be supplied in
URLs.

`MCP_HTTP_MAX_BODY_BYTES` and `MCP_HTTP_MAX_RESPONSE_BYTES` default to 1 MiB.
`MCP_HTTP_CONCURRENCY_LIMIT` defaults to 16, and
`MCP_HTTP_REQUEST_TIMEOUT_MS` defaults to 10000, and
`MCP_HTTP_SESSION_TTL_MS` defaults to 15 minutes. Host and Origin allowlists
are checked before authentication and before any MCP handler runs. POST carries
JSON-RPC, GET opens the session SSE stream, and DELETE closes the session. The
modern `2026-07-28` Streamable HTTP envelope remains planned because the pinned
stateful adapter does not classify modern envelopes; it is not advertised as
supported.

The server resolves `OBSIDIAN_LOCAL_MD` through the existing stable resolver.
The stdio entrypoint does not start an HTTP listener. Neither entrypoint exposes vault mutation tools. Repository
metadata is limited to the adapter repository root by default; set the
path-delimited `MCP_REPOSITORY_ROOTS` environment variable to approve additional
local repository roots.

The taxonomy resource returns only the project-taxonomy table. Tool arguments
are validated inside the handlers so invalid input uses the stable structured
error contract instead of leaking SDK validation text.

The machine-readable contract is [`contract.json`](contract.json). Its fixture
cases are in [`test/fixtures/contract-fixtures.json`](test/fixtures/contract-fixtures.json)
and are checked by `test/contract.test.mjs`.

Prompts, legacy HTTP+SSE, and writes remain explicitly gated in the contract.
