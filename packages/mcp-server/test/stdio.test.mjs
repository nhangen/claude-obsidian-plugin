import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const entrypoint = join(packageRoot, "src", "stdio.mjs");
const repositoryRoot = resolve(packageRoot, "../..");

function startServer(configPath) {
  const child = spawn(process.execPath, [entrypoint], {
    cwd: tmpdir(),
    env: { ...process.env, OBSIDIAN_LOCAL_MD: configPath },
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
            setTimeout(() => reject(new Error(`timed out waiting for MCP response ${id}`)), 2000);
          }),
        ]);
      }
    },
    notification(message) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    },
    messages,
  };
}

test("stdio server exposes read-only tools with clean MCP framing", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-stdio-"));
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(vault);
  await writeFile(join(vault, "mcp-note.md"), "# MCP note\nThis fixture is searchable.\n");
  await writeFile(join(vault, "other.md"), "# Other note\n");
  await writeFile(config, `---\nvault_path: ${vault}\n---\n`);

  const server = startServer(config);
  t.after(async () => {
    if (!server.child.killed) server.child.stdin.end();
    await Promise.race([
      once(server.child, "close").catch(() => {}),
      new Promise((resolveWait) => setTimeout(resolveWait, 100)),
    ]);
    await rm(fixture, { recursive: true, force: true });
  });

  const initialized = await server.request(
    {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-11-25",
        capabilities: {},
        clientInfo: { name: "stdio-contract-test", version: "1.0.0" },
      },
    },
    1,
  );
  assert.equal(initialized.jsonrpc, "2.0");
  assert.equal(initialized.id, 1);
  assert.equal(typeof initialized.result?.serverInfo?.name, "string");
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });

  const tools = await server.request(
    { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
    2,
  );
  const toolNames = tools.result.tools.map((tool) => tool.name);
  assert.deepEqual(toolNames.sort(), ["obsidian_commit_meta", "obsidian_find_notes"]);

  const search = await server.request(
    {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "obsidian_find_notes", arguments: { query: "MCP" } },
    },
    3,
  );
  assert.equal(search.result?.isError, false);
  assert.match(search.result?.content?.[0]?.text ?? "", /mcp-note\.md/);

  const metadata = await server.request(
    {
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: {
        name: "obsidian_commit_meta",
        arguments: { repository: repositoryRoot },
      },
    },
    4,
  );
  assert.equal(metadata.result?.isError, false);
  assert.match(metadata.result?.content?.[0]?.text ?? "", /hash=/);
  assert.match(metadata.result?.content?.[0]?.text ?? "", /vault_path=/);

  server.notification({
    jsonrpc: "2.0",
    method: "notifications/cancelled",
    params: { requestId: 999, reason: "contract test" },
  });
  const afterCancellation = await server.request(
    { jsonrpc: "2.0", id: 5, method: "tools/list", params: {} },
    5,
  );
  assert.equal(afterCancellation.id, 5);

  const invalid = await server.request(
    { jsonrpc: "2.0", id: 6, method: "not-a-real-method", params: {} },
    6,
  );
  assert.equal(invalid.error?.code, -32601);
  assert.equal(server.child.exitCode, null);
  assert.equal(server.messages.some((message) => message.parseFailure), false);

  server.child.stdin.end();
  const [exitCode] = await once(server.child, "exit");
  assert.equal(exitCode, 0);
  assert.equal(server.messages.some((message) => message.parseFailure), false);
  assert.doesNotMatch(server.stderr(), /stdout|MCP message/i);
});
