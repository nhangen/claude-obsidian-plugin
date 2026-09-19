# MCP server

This package is the isolated local MCP adapter for `claude-obsidian-plugin`.
It runs over stdio and exposes only the read-only `obsidian_find_notes` and
`obsidian_commit_meta` tools. The existing root plugin, hooks, commands, and
keeper remain unchanged.

```bash
npm ci
npm test
npm start
```

The server resolves `OBSIDIAN_LOCAL_MD` through the existing stable resolver.
It does not start an HTTP listener or expose vault mutation tools.
