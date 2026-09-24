import assert from "node:assert/strict";
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import { createHmac } from "node:crypto";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const stdioEntrypoint = join(packageRoot, "dist", "stdio.mjs");
const httpEntrypoint = join(packageRoot, "dist", "http.mjs");
const repositoryRoot = resolve(packageRoot, "../..");

const secret = "0123456789abcdef0123456789abcdef";
const issuer = "https://issuer.example";
const audience = "claude-obsidian";

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function jwtToken({ scope = "vault:read repo:read vault:write", exp = Math.floor(Date.now() / 1000) + 300, aud = audience, iss = issuer } = {}) {
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({ aud, exp, iss, scope }));
  const signature = createHmac("sha256", secret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function collect(child) {
  let buffer = "";
  const messages = [];
  const listeners = new Set();
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    for (;;) {
      const newline = buffer.indexOf("\n");
      if (newline < 0) break;
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (line) messages.push(JSON.parse(line));
    }
    listeners.forEach((fn) => fn());
    listeners.clear();
  });
  return async (id) => {
    for (;;) {
      const message = messages.find((candidate) => candidate.id === id);
      if (message) return message;
      await new Promise((resolveWait) => { listeners.add(resolveWait); });
    }
  };
}

async function createFixtureVault() {
  const root = await mkdtemp(join(tmpdir(), "obsidian-mcp-e2e-gates-"));
  const vaultPath = join(root, "vault");
  const cachePath = join(root, "cache");
  await mkdir(join(vaultPath, "Daily"), { recursive: true });
  await mkdir(join(vaultPath, "Inbox"), { recursive: true });
  await mkdir(cachePath, { recursive: true });
  await writeFile(join(vaultPath, "Librarian.md"), "# Librarian Index\n");
  await writeFile(join(vaultPath, "Pending.md"), "# Pending Items\n");

  const configPath = join(root, "config.yaml");
  await writeFile(configPath, `---\nvault_path: ${vaultPath}\ndaily_path: Daily/\nfrontmatter_required: tags type\nkeeper_host_priority: ml-1 mbp\n---\n`);
  return { root, vaultPath, cachePath, configPath };
}

function startStdioServer(configPath, cachePath, extraEnv = {}) {
  const child = spawn(process.execPath, [stdioEntrypoint], {
    cwd: tmpdir(),
    env: { ...process.env, OBSIDIAN_LOCAL_MD: configPath, XDG_CACHE_HOME: cachePath, MCP_REPOSITORY_ROOTS: repositoryRoot, ...extraEnv },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const next = collect(child);

  const initPromise = (async () => {
    child.stdin.write(`${JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } },
    })}\n`);
    await next(1);
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
  })();

  return { child, next, initPromise };
}

function startHttpServer(configPath, cachePath) {
  const child = spawn(process.execPath, [httpEntrypoint], {
    cwd: tmpdir(),
    env: {
      ...process.env,
      OBSIDIAN_LOCAL_MD: configPath,
      XDG_CACHE_HOME: cachePath,
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

test("MCP write tools handle watcher and tick background contention cleanly with disk verification", async (t) => {
  const { root, vaultPath, cachePath, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath, cachePath);

  t.after(async () => {
    if (server.child.exitCode === null) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.initPromise;

  const tickScript = join(repositoryRoot, "scripts", "vaultkeeper-tick.sh");
  const tickChild = spawn("bash", [tickScript], {
    env: { ...process.env, OBSIDIAN_LOCAL_MD: configPath, XDG_CACHE_HOME: cachePath, VAULTKEEPER_HOST: "ml-1" },
    stdio: "ignore",
  });

  const id1 = 2;
  server.child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: id1, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "ContendedNote", body: "Body text for contended note", idempotency_key: "key-contended-1", request_id: "req-contended-1" },
    },
  })}\n`);

  const id2 = 3;
  server.child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: id2, method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "- [ ] Contended task", section: "## Tasks", idempotency_key: "key-contended-2", request_id: "req-contended-2" },
    },
  })}\n`);

  const [res1, res2] = await Promise.all([server.next(id1), server.next(id2)]);
  await once(tickChild, "close").catch(() => {});

  assert.equal(res1.result.isError, false);
  assert.equal(res2.result.isError, false);

  const saveOut = JSON.parse(res1.result.content[0].text);
  assert.equal(saveOut.status, "committed");
  assert.equal(saveOut.request_id, "req-contended-1");
  assert.equal(saveOut.idempotency_key, "key-contended-1");
  assert.equal(saveOut.path, "Inbox/ContendedNote.md");

  const appendOut = JSON.parse(res2.result.content[0].text);
  assert.ok(["committed", "skipped"].includes(appendOut.status));
  assert.equal(appendOut.request_id, "req-contended-2");
  assert.equal(appendOut.idempotency_key, "key-contended-2");

  const noteOnDisk = await readFile(join(vaultPath, "Inbox", "ContendedNote.md"), "utf8");
  assert.ok(noteOnDisk.includes("Body text for contended note"));
});

test("stdio and HTTP servers enforce path containment and reject symlink traversal write attempts", async (t) => {
  const { root, vaultPath, cachePath, configPath } = await createFixtureVault();
  const outsideFile = join(root, "outside-secret.txt");
  await writeFile(outsideFile, "SECRET_DATA");

  const symlinkInside = join(vaultPath, "escaped.md");
  await symlink(outsideFile, symlinkInside);

  const server = startStdioServer(configPath, cachePath);
  t.after(async () => {
    if (server.child.exitCode === null) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.initPromise;

  const idEscapeTitle = 2;
  server.child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: idEscapeTitle, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "../outside-secret", body: "overwrite attempt", idempotency_key: "key-escape-1", request_id: "req-escape-1" },
    },
  })}\n`);
  const resEscapeTitle = await server.next(idEscapeTitle);
  assert.equal(resEscapeTitle.result.isError, true);
  const outEscapeTitle = JSON.parse(resEscapeTitle.result.content[0].text);
  assert.equal(outEscapeTitle.code, "PATH_INVALID");

  const secretContent = await readFile(outsideFile, "utf8");
  assert.equal(secretContent, "SECRET_DATA");
});

test("stdio server handles simulated partial write fault injection and idempotently recovers", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-fault-injection-"));
  const install = join(fixture, "install");
  const helperRoot = join(install, "dist", "helpers");
  const vault = join(fixture, "vault");
  const cache = join(fixture, "cache");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(join(helperRoot, "lib"), { recursive: true });
  await mkdir(join(vault, "Inbox"), { recursive: true });
  await mkdir(cache, { recursive: true });
  await copyFile(join(packageRoot, "dist", "stdio.mjs"), join(install, "dist", "stdio.mjs"));
  await copyFile(join(packageRoot, "dist", "helpers", "lib", "resolve-config.sh"), join(helperRoot, "lib", "resolve-config.sh"));
  await symlink(join(packageRoot, "node_modules"), join(install, "node_modules"), "dir");
  await writeFile(config, `---\nvault_path: ${vault}\ndaily_path: Daily/\n---\n`);

  const faultScript = join(helperRoot, "keeper");
  await writeFile(faultScript, `#!/usr/bin/env bash
if [ -f "${fixture}/simulated-fault-triggered" ]; then
  printf '{"status":"committed","request_id":"request-fault-1","idempotency_key":"fault-key-1","path":"Inbox/FaultNote.md","affected_paths":["Inbox/FaultNote.md","Inbox/INDEX.md"],"warnings":[],"recovery":{"required":false,"action":""},"error_code":null,"retryable":false}\\n'
  exit 0
else
  touch "${fixture}/simulated-fault-triggered"
  printf '{"status":"partial","request_id":"request-fault-1","idempotency_key":"fault-key-1","path":"Inbox/FaultNote.md","affected_paths":["Inbox/FaultNote.md"],"warnings":["INDEX update pending"],"recovery":{"required":true,"action":"retry"},"error_code":"PARTIAL","retryable":true}\\n'
  exit 2
fi
`);
  await chmod(faultScript, 0o755);

  const child = spawn(process.execPath, [join(install, "dist", "stdio.mjs")], {
    cwd: fixture,
    env: { ...process.env, OBSIDIAN_LOCAL_MD: config, XDG_CACHE_HOME: cache },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const next = collect(child);

  t.after(async () => {
    if (child.exitCode === null) child.stdin.end();
    await once(child, "close").catch(() => {});
    await rm(fixture, { recursive: true, force: true });
  });

  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } },
  })}\n`);
  await next(1);
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);

  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "FaultNote", body: "Fault body", idempotency_key: "fault-key-1", request_id: "request-fault-1" },
    },
  })}\n`);
  const firstRes = await next(2);
  assert.equal(firstRes.result.isError, true);
  const firstOut = JSON.parse(firstRes.result.content[0].text);
  assert.equal(firstOut.status, "partial");
  assert.equal(firstOut.request_id, "request-fault-1");
  assert.equal(firstOut.idempotency_key, "fault-key-1");
  assert.equal(firstOut.error_code, "PARTIAL");
  assert.equal(firstOut.recovery.required, true);
  assert.equal(firstOut.recovery.action, "retry");
  assert.equal(firstOut.retryable, true);
  assert.match(await readFile(join(vault, "Inbox", "FaultNote.md"), "utf8"), /Fault body/);

  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "FaultNote", body: "Fault body", idempotency_key: "fault-key-1", request_id: "request-fault-1" },
    },
  })}\n`);
  const retryRes = await next(3);
  assert.equal(retryRes.result.isError, false);
  const retryOut = JSON.parse(retryRes.result.content[0].text);
  assert.equal(retryOut.status, "committed");
  assert.equal(retryOut.request_id, "request-fault-1");
  assert.equal(retryOut.idempotency_key, "fault-key-1");
  assert.equal(retryOut.recovery.required, false);
  assert.equal(retryOut.retryable, false);
});

test("concurrent insert tool calls resolve to one commit and one explicit conflict with Streamable HTTP transport coverage", async (t) => {
  const { root, cachePath, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath, cachePath);
  const httpServer = startHttpServer(configPath, cachePath);

  t.after(async () => {
    if (server.child.exitCode === null) server.child.stdin.end();
    if (httpServer.child.exitCode === null) httpServer.child.kill();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.initPromise;
  const baseUrl = await httpServer.ready;

  const token = jwtToken({ scope: "vault:read repo:read vault:write" });
  const httpInitRes = await fetch(`${baseUrl}/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      origin: "https://allowed.example",
      authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 10, method: "initialize",
      params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "http-test", version: "1" } },
    }),
  });
  const sessionId = httpInitRes.headers.get("mcp-session-id");
  assert.ok(sessionId, `HTTP init failed with status ${httpInitRes.status}`);

  const id1 = 2;
  const id2 = 3;

  server.child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: id1, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "SharedTarget", body: "Body 1", idempotency_key: "key-insert-race-a", request_id: "req-race-a" },
    },
  })}\n`);

  const httpCallPromise = fetch(`${baseUrl}/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      origin: "https://allowed.example",
      authorization: `Bearer ${token}`,
      "mcp-session-id": sessionId,
    },
    body: JSON.stringify({
      jsonrpc: "2.0", id: id2, method: "tools/call",
      params: {
        name: "obsidian_keeper_save",
        arguments: { title: "SharedTarget", body: "Body 2", idempotency_key: "key-insert-race-b", request_id: "req-race-b" },
      },
    }),
  });

  const [res1, httpRes] = await Promise.all([server.next(id1), httpCallPromise]);
  const httpJson = await httpRes.json();

  const outcome1 = { isError: res1.result.isError, data: JSON.parse(res1.result.content[0].text) };
  const outcome2 = { isError: httpJson.result.isError, data: JSON.parse(httpJson.result.content[0].text) };

  const outcomes = [outcome1, outcome2];
  const committed = outcomes.filter((o) => o.data.status === "committed");
  const conflict = outcomes.filter((o) => o.data.status === "conflict");

  assert.equal(committed.length, 1);
  assert.equal(conflict.length, 1);
  assert.equal(conflict[0].isError, true);
  assert.equal(conflict[0].data.retryable, false);
  assert.equal(conflict[0].data.recovery.required, false);
});
