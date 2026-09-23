import assert from "node:assert/strict";
import { basename } from "node:path";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));

for (const client of ["claude", "cursor"]) {
  test(`${client} manifest uses the installed package launcher and literal configuration paths`, async () => {
    const manifest = JSON.parse(await readFile(new URL(`../examples/manifests/${client}-mcp.json`, import.meta.url), "utf8"));
    const server = manifest.mcpServers.obsidian;

    assert.equal(basename(server.command), "claude-obsidian-mcp");
    assert.equal(server.command, "/absolute/path/to/node_modules/.bin/claude-obsidian-mcp");
    assert.equal(packageJson.bin[basename(server.command)], "dist/stdio.mjs");
    assert.deepEqual(server.args, []);
    assert.equal(server.env.OBSIDIAN_LOCAL_MD, "/absolute/path/to/obsidian.local.md");
    assert.equal(server.env.MCP_REPOSITORY_ROOTS, "/absolute/path/to/repository");
    assert.doesNotMatch(JSON.stringify(manifest), /\$\{|@nhangen\/obsidian-mcp/);
  });
}
