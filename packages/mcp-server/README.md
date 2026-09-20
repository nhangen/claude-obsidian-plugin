# MCP server

This package is the isolated local MCP adapter for `claude-obsidian-plugin`.
It runs over stdio and exposes the read-only `obsidian_find_notes` and
`obsidian_commit_meta` tools plus bounded read-only resources for taxonomy,
daily notes, the librarian index, and pending items. The existing root plugin,
hooks, commands, and keeper remain unchanged.

```bash
npm ci
npm test
npm start
```

The server resolves `OBSIDIAN_LOCAL_MD` through the existing stable resolver.
It does not start an HTTP listener or expose vault mutation tools.

The machine-readable contract is [`contract.json`](contract.json). Its fixture
cases are in [`test/fixtures/contract-fixtures.json`](test/fixtures/contract-fixtures.json)
and are checked by `test/contract.test.mjs`.

Streamable HTTP, prompts, and writes remain explicitly gated in the contract
until their linked implementation issues are complete.
