import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const stdioEntrypoint = join(packageRoot, "src", "stdio.mjs");
const repositoryRoot = resolve(packageRoot, "../..");

async function createFixtureVault() {
  const root = await mkdtemp(join(tmpdir(), "obsidian-mcp-prompts-test-"));
  const vaultPath = join(root, "vault");
  await mkdir(vaultPath, { recursive: true });
  await writeFile(join(vaultPath, "Librarian.md"), "# Librarian Index\n- [[Note1]]\n");
  await writeFile(join(vaultPath, "Pending.md"), "# Pending Items\n- [ ] Task 1\n");

  const configPath = join(root, "config.yaml");
  await writeFile(configPath, `---\nvault_path: ${vaultPath}\n---\n`);
  return { root, vaultPath, configPath };
}

function startStdioServer(configPath) {
  const child = spawn(process.execPath, [stdioEntrypoint], {
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
            setTimeout(() => reject(new Error(`timed out waiting for MCP response ${id}`)), 8000);
          }),
        ]);
      }
    },
    notification(message) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    },
  };
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

  const promptsList = await server.request({
    jsonrpc: "2.0",
    id: 2,
    method: "prompts/list",
    params: {},
  }, 2);

  assert.equal(promptsList.jsonrpc, "2.0");
  assert.equal(promptsList.id, 2);
  assert.ok(Array.isArray(promptsList.result.prompts));
  const promptNames = promptsList.result.prompts.map((prompt) => prompt.name).sort();
  assert.deepEqual(promptNames, ["obsidian_ask", "reorganize_vault", "summarize_session"]);
});

test("stdio server returns prompt content via prompts/get for obsidian_ask", async (t) => {
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
    params: { name: "obsidian_ask", arguments: { query: "recent decisions" } },
  }, 2);

  assert.equal(promptGet.jsonrpc, "2.0");
  assert.equal(promptGet.id, 2);
  assert.ok(promptGet.result.messages.length > 0);
  assert.ok(promptGet.result.messages[0].content.text.includes("vault librarian"));
  assert.ok(promptGet.result.messages[0].content.text.includes("recent decisions"));
});
