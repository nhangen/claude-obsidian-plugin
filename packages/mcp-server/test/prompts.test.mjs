import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const entrypoint = join(packageRoot, "src", "stdio.mjs");
const repositoryRoot = resolve(packageRoot, "../..");

function startStdioServer(configPath) {
  const child = spawn(process.execPath, [entrypoint], {
    cwd: tmpdir(),
    env: { ...process.env, OBSIDIAN_LOCAL_MD: configPath, MCP_REPOSITORY_ROOTS: repositoryRoot },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  let childError;
  const messages = [];
  let messageWaiter;

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
    for (;;) {
      const newline = stdout.indexOf("\n");
      if (newline < 0) break;
      const line = stdout.slice(0, newline).trim();
      stdout = stdout.slice(newline + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        message = { parseFailure: error.message, line };
      }
      messages.push(message);
      messageWaiter?.();
      messageWaiter = undefined;
    }
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  child.on("error", (error) => {
    childError = error;
    messageWaiter?.();
    messageWaiter = undefined;
  });

  return {
    child,
    stderr: () => stderr,
    async request(message, id) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
      for (;;) {
        if (childError) throw childError;
        const response = messages.find((candidate) => candidate.id === id);
        if (response) return response;
        await Promise.race([
          new Promise((resolveWait) => {
            messageWaiter = resolveWait;
          }),
          new Promise((_, reject) => {
            setTimeout(() => reject(new Error(`timed out waiting for MCP response ${id}`)), 5000);
          }),
        ]);
      }
    },
    notification(message) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    },
  };
}

async function createFixtureVault() {
  const root = await mkdtemp(join(tmpdir(), "mcp-prompt-test-"));
  const vaultPath = join(root, "vault");
  const configDir = join(root, "config");
  await mkdir(vaultPath, { recursive: true });
  await mkdir(configDir, { recursive: true });

  const configPath = join(configDir, "obsidian.local.md");
  const configContent = `---
vault_path: ${vaultPath}
daily_path: Daily/
---

## Project Taxonomy
| Domain | Path | Keywords |
|---|---|---|
| Development | Projects/Development/ | dev, code |
`;
  await writeFile(configPath, configContent, "utf8");
  return { root, vaultPath, configPath };
}

test("stdio server lists prompts via prompts/list", async (t) => {
  const { root, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath);

  t.after(async () => {
    if (!server.child.killed) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.request({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });

  const promptList = await server.request({
    jsonrpc: "2.0",
    id: 2,
    method: "prompts/list",
    params: {},
  }, 2);

  assert.equal(promptList.jsonrpc, "2.0");
  assert.equal(promptList.id, 2);
  const promptNames = promptList.result.prompts.map((p) => p.name).sort();
  assert.deepEqual(promptNames, ["ask_vault_librarian", "summarize_session"]);
});

test("stdio server returns prompt content via prompts/get for ask_vault_librarian", async (t) => {
  const { root, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath);

  t.after(async () => {
    if (!server.child.killed) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.request({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });

  const promptGet = await server.request({
    jsonrpc: "2.0",
    id: 2,
    method: "prompts/get",
    params: { name: "ask_vault_librarian", arguments: { query: "recent decisions" } },
  }, 2);

  assert.equal(promptGet.jsonrpc, "2.0");
  assert.equal(promptGet.id, 2);
  assert.ok(promptGet.result.messages.length > 0);
  assert.ok(promptGet.result.messages[0].content.text.includes("vault librarian"));
  assert.ok(promptGet.result.messages[0].content.text.includes("INDEX.md"));
  assert.ok(promptGet.result.messages[0].content.text.includes("deduplication"));
  assert.ok(promptGet.result.messages[0].content.text.includes("Pending.md"));
  assert.ok(promptGet.result.messages[0].content.text.includes("recent decisions"));
});

test("stdio server refuses the admin-only reorganize_vault prompt", async (t) => {
  const { root, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath);

  t.after(async () => {
    if (!server.child.killed) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.request({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });

  const promptGet = await server.request({
    jsonrpc: "2.0",
    id: 2,
    method: "prompts/get",
    params: { name: "reorganize_vault", arguments: {} },
  }, 2);

  assert.equal(promptGet.jsonrpc, "2.0");
  assert.equal(promptGet.id, 2);
  assert.equal(promptGet.error?.code, -32602);
  assert.match(promptGet.error?.message ?? "", /Prompt .* not found/);
});
