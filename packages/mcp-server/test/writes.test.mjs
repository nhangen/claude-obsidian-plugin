import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import { createHmac } from "node:crypto";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const stdioEntrypoint = join(packageRoot, "src", "stdio.mjs");
const httpEntrypoint = join(packageRoot, "src", "http.mjs");
const repositoryRoot = resolve(packageRoot, "../..");
const secret = "0123456789abcdef0123456789abcdef";
const issuer = "https://issuer.example";
const audience = "claude-obsidian";

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function jwtToken({ scope = "vault:read repo:read", exp = Math.floor(Date.now() / 1000) + 300, aud = audience, iss = issuer } = {}) {
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({ aud, exp, iss, scope }));
  const signature = createHmac("sha256", secret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function startStdioServer(configPath, extraEnv = {}) {
  const child = spawn(process.execPath, [stdioEntrypoint], {
    cwd: tmpdir(),
    env: { ...process.env, OBSIDIAN_LOCAL_MD: configPath, MCP_REPOSITORY_ROOTS: repositoryRoot, ...extraEnv },
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

function startHttpServer(configPath) {
  const child = spawn(process.execPath, [httpEntrypoint], {
    cwd: tmpdir(),
    env: {
      ...process.env,
      OBSIDIAN_LOCAL_MD: configPath,
      MCP_HTTP_BIND: "127.0.0.1",
      MCP_HTTP_PORT: "0",
      MCP_HTTP_JWT_SECRET: secret,
      MCP_HTTP_JWT_ISSUER: issuer,
      MCP_HTTP_JWT_AUDIENCE: audience,
      MCP_HTTP_ALLOWED_HOSTS: "127.0.0.1,localhost",
      MCP_HTTP_ALLOWED_ORIGINS: "https://allowed.example",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolveReady, rejectReady) => {
    readyResolve = resolveReady;
    readyReject = rejectReady;
  });

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    const match = stderr.match(/mcp-http-listening (http:\/\/127\.0\.0\.1:\d+)/);
    if (match) readyResolve(match[1]);
  });
  child.on("error", (error) => readyReject(error));
  child.on("close", (code) => {
    if (code !== 0) readyReject(new Error(`HTTP server exited with ${code}: ${stderr}`));
  });

  return { child, ready };
}

async function createFixtureVault() {
  const root = await mkdtemp(join(tmpdir(), "mcp-write-test-"));
  const vaultPath = join(root, "vault");
  const configDir = join(root, "config");
  await mkdir(vaultPath, { recursive: true });
  await mkdir(join(vaultPath, "Daily"), { recursive: true });
  await mkdir(join(vaultPath, "Inbox"), { recursive: true });
  await mkdir(join(vaultPath, "Projects"), { recursive: true });
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

test("stdio server executes obsidian_keeper_save tool call", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
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

  const saveResponse = await server.request({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Test Note", body: "Sample body content", folder_hint: "Inbox" },
    },
  }, 2);

  assert.equal(saveResponse.jsonrpc, "2.0");
  assert.equal(saveResponse.id, 2);
  assert.equal(saveResponse.result.isError, false);
  const data = JSON.parse(saveResponse.result.content[0].text);
  assert.equal(data.status, "committed");
  assert.equal(data.path, "Inbox/Test Note.md");
});

test("stdio server executes obsidian_daily_append with skip_if_hash idempotency", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
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

  const sha = "0123456789abcdef";
  const first = await server.request({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "First commit log entry", section: `## ${sha} — msg`, date: "2026-09-22", skip_if_hash: sha },
    },
  }, 2);
  assert.equal(first.result.isError, false);
  assert.equal(JSON.parse(first.result.content[0].text).status, "committed");

  const second = await server.request({
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "Duplicate entry", section: `## ${sha} — msg`, date: "2026-09-22", skip_if_hash: sha },
    },
  }, 3);
  assert.equal(second.result.isError, false);
  assert.equal(JSON.parse(second.result.content[0].text).status, "skipped");
});

test("stdio server rejects path traversal escape attempts", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
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

  const traversalResponse = await server.request({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Bad Note", body: "Escaping", folder_hint: "../../outside" },
    },
  }, 2);

  assert.equal(traversalResponse.result.isError, true);
  const error = JSON.parse(traversalResponse.result.content[0].text);
  assert.equal(error.code, "PATH_INVALID");
});

test("Streamable HTTP transport enforces scope gating on write tools", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const server = startHttpServer(configPath);
  const url = await server.ready;

  t.after(async () => {
    if (!server.child.killed) server.child.kill("SIGTERM");
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  const readOnlyToken = jwtToken({ scope: "vault:read repo:read" });
  const writeToken = jwtToken({ scope: "vault:read vault:write" });

  function headers(tokenStr, extra = {}) {
    return {
      Accept: "application/json, text/event-stream",
      Host: "127.0.0.1",
      Origin: "https://allowed.example",
      Authorization: `Bearer ${tokenStr}`,
      "Content-Type": "application/json",
      ...extra,
    };
  }

  // 1. Session with read-only token
  const initRead = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(readOnlyToken),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
    }),
  });
  assert.equal(initRead.status, 200);
  const readSessionId = initRead.headers.get("mcp-session-id");

  // Read-only token write attempt -> 403 Forbidden
  const writeAttemptForbidden = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(readOnlyToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": readSessionId }),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "obsidian_daily_append", arguments: { content: "Forbidden write" } },
    }),
  });
  assert.equal(writeAttemptForbidden.status, 403);

  // 2. Session with write token
  const initWrite = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(writeToken),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
    }),
  });
  assert.equal(initWrite.status, 200);
  const writeSessionId = initWrite.headers.get("mcp-session-id");

  // Write token write call -> 200 Success
  const writeAllowed = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(writeToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": writeSessionId }),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "obsidian_daily_append", arguments: { content: "Authorized HTTP entry", date: "2026-09-22" } },
    }),
  });
  assert.equal(writeAllowed.status, 200);
  const writeResult = await writeAllowed.json();
  assert.equal(writeResult.result.isError, false);
  assert.equal(JSON.parse(writeResult.result.content[0].text).status, "committed");
});
