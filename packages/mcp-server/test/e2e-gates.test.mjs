import assert from "node:assert/strict";
import { access, cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import { createHash, createHmac } from "node:crypto";

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
  const installPath = join(root, "install");
  const vaultPath = join(root, "vault");
  const cachePath = join(root, "cache");
  await cp(join(packageRoot, "dist"), join(installPath, "dist"), { recursive: true });
  await symlink(join(packageRoot, "node_modules"), join(installPath, "node_modules"), "dir");
  await mkdir(join(vaultPath, "Daily"), { recursive: true });
  await mkdir(join(vaultPath, "Inbox"), { recursive: true });
  await mkdir(cachePath, { recursive: true });
  await writeFile(join(vaultPath, "Librarian.md"), "# Librarian Index\n");
  await writeFile(join(vaultPath, "Pending.md"), "# Pending Items\n");

  const configPath = join(root, "config.yaml");
  await writeFile(configPath, `---\nvault_path: ${vaultPath}\ndaily_path: Daily/\nfrontmatter_required: tags type\nkeeper_host_priority: ml-1 mbp\n---\n`);
  return {
    root,
    vaultPath,
    cachePath,
    configPath,
    keeperPath: join(installPath, "dist", "helpers", "keeper"),
    stdioPath: join(installPath, "dist", "stdio.mjs"),
    httpPath: join(installPath, "dist", "http.mjs"),
  };
}

function startStdioServer(configPath, cachePath, extraEnv = {}, entrypoint = stdioEntrypoint) {
  const child = spawn(process.execPath, [entrypoint], {
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

function startHttpServer(configPath, cachePath, extraEnv = {}, entrypoint = httpEntrypoint) {
  const child = spawn(process.execPath, [entrypoint], {
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
      ...extraEnv,
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

function responseOutcome(response) {
  return response.result.structuredContent ?? JSON.parse(response.result.content[0].text);
}

function assertSuccessOutcome(outcome, expected) {
  assert.deepEqual(outcome, {
    status: expected.status,
    request_id: expected.requestId,
    idempotency_key: expected.idempotencyKey,
    path: expected.path,
    affected_paths: expected.affectedPaths,
    warnings: [],
    recovery: { required: false, action: "" },
    error_code: null,
    retryable: false,
  });
}

function assertFailureOutcome(outcome, expected) {
  assert.deepEqual(outcome, {
    code: expected.errorCode,
    detail: expected.detail,
    status: expected.status,
    request_id: expected.requestId,
    idempotency_key: expected.idempotencyKey,
    path: expected.path,
    affected_paths: expected.affectedPaths,
    warnings: expected.warnings ?? [],
    recovery: {
      required: expected.recoveryRequired,
      action: expected.recoveryAction,
    },
    error_code: expected.errorCode,
    retryable: expected.retryable,
  });
}

async function initializeHttp(server, id) {
  const baseUrl = await server.ready;
  const headers = {
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
    origin: "https://allowed.example",
    authorization: `Bearer ${jwtToken()}`,
  };
  const response = await fetch(`${baseUrl}/mcp`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      jsonrpc: "2.0",
      id,
      method: "initialize",
      params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "e2e-gate", version: "1" } },
    }),
  });
  assert.equal(response.status, 200);
  const sessionId = response.headers.get("mcp-session-id");
  assert.ok(sessionId);
  return { baseUrl, headers: { ...headers, "mcp-session-id": sessionId } };
}

async function httpToolCall(session, id, name, args) {
  const response = await fetch(`${session.baseUrl}/mcp`, {
    method: "POST",
    headers: session.headers,
    body: JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } }),
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function waitForPath(path) {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    try {
      await access(path);
      return;
    } catch {}
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  throw new Error(`timed out waiting for ${path}`);
}

async function waitForWaiters(path, count) {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    const waiters = await readdir(path);
    if (waiters.length >= count) return waiters;
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  throw new Error(`timed out waiting for ${count} waiters in ${path}`);
}

async function stopChild(child, signal = "SIGTERM", timeoutMs = 500) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const closed = once(child, "close");
  child.kill(signal);
  let forceKill;
  if (signal !== "SIGKILL") {
    forceKill = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, timeoutMs);
    forceKill.unref();
  }
  try {
    await closed;
  } finally {
    if (forceKill) clearTimeout(forceKill);
  }
}

test("MCP write, packaged keeper producer, and tick serialize on the canonical vault lock", async (t) => {
  const { root, vaultPath, cachePath, configPath, keeperPath, stdioPath } = await createFixtureVault();
  const waitDir = join(root, "lock-waiters");
  const server = startStdioServer(configPath, cachePath, { KEEPER_TEST_WAIT_DIR: waitDir }, stdioPath);
  const pauseDir = join(root, "tick-pause");
  await mkdir(pauseDir);
  await mkdir(waitDir);
  const section = "## a1b2c3d4 — contended hook capture";
  const target = "Daily/2026-09-26.md";
  const sharedArgs = {
    content: "Contended hook body",
    section,
    date: "2026-09-26",
    skip_if_hash: "a1b2c3d4",
    idempotency_key: "key-contended-hook",
  };
  const tickChild = spawn("bash", [join(repositoryRoot, "scripts", "vaultkeeper-tick.sh")], {
    env: {
      ...process.env,
      OBSIDIAN_LOCAL_MD: configPath,
      XDG_CACHE_HOME: cachePath,
      VAULTKEEPER_HOST: "ml-1",
      KEEPER_TEST_PAUSE_POINT: "after_lock_owner",
      KEEPER_TEST_PAUSE_DIR: pauseDir,
    },
    stdio: "ignore",
  });
  const tickClosed = once(tickChild, "close");
  let producerStdout = "";
  let producerStderr = "";
  let producer;

  t.after(async () => {
    if (producer?.exitCode === null) await stopChild(producer, "SIGKILL");
    if (tickChild.exitCode === null) await stopChild(tickChild, "SIGKILL");
    await stopChild(server.child);
    await rm(root, { recursive: true, force: true });
  });

  await server.initPromise;
  await waitForPath(join(pauseDir, "ready"));
  const lockHash = createHash("sha256").update(await realpath(vaultPath)).digest("hex");
  const lockPath = join("/tmp", `claude-obsidian-keeper-${process.getuid()}`, `${lockHash}.lock`);
  assert.equal((await readFile(lockPath, "utf8")).split("\n", 1)[0], String(tickChild.pid));
  assert.equal(tickChild.exitCode, null);

  producer = spawn("bash", [
    keeperPath,
    "append",
    "--vault", vaultPath,
    "--target", target,
    "--section", section,
    "--skip-if-hash", "a1b2c3d4",
    "--request-id", "req-contended-hook",
    "--idempotency-key", sharedArgs.idempotency_key,
    "--format", "json",
  ], {
    env: { ...process.env, KEEPER_TEST_WAIT_DIR: waitDir },
    stdio: ["pipe", "pipe", "pipe"],
  });
  producer.stdout.setEncoding("utf8");
  producer.stderr.setEncoding("utf8");
  producer.stdout.on("data", (chunk) => { producerStdout += chunk; });
  producer.stderr.on("data", (chunk) => { producerStderr += chunk; });
  const producerClosed = once(producer, "close");
  producer.stdin.end(sharedArgs.content);

  const id = 2;
  server.child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id, method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { ...sharedArgs, request_id: "req-contended-mcp" },
    },
  })}\n`);
  const mcpResponse = server.next(id);

  const producerWaiter = join(waitDir, String(producer.pid));
  await waitForPath(producerWaiter);
  const waiters = await waitForWaiters(waitDir, 2);
  assert.equal(waiters.length, 2);
  assert.ok(waiters.includes(String(producer.pid)));
  const mcpWaiter = waiters.find((waiter) => waiter !== String(producer.pid));
  assert.ok(mcpWaiter);
  await access(producerWaiter);
  await access(join(waitDir, mcpWaiter));
  await writeFile(join(pauseDir, "continue"), "continue\n");
  const [mcpResult, producerClose, tickClose] = await Promise.all([
    mcpResponse,
    producerClosed,
    tickClosed,
  ]);

  assert.deepEqual(producerClose, [0, null], producerStderr);
  const producerOutcome = JSON.parse(producerStdout);
  const mcpOutcome = responseOutcome(mcpResult);
  assert.deepEqual([producerOutcome.status, mcpOutcome.status].sort(), ["committed", "skipped"]);
  assertSuccessOutcome(producerOutcome, {
    status: producerOutcome.status,
    requestId: "req-contended-hook",
    idempotencyKey: sharedArgs.idempotency_key,
    path: target,
    affectedPaths: [target],
  });
  assert.equal(mcpResult.result.isError, false);
  assertSuccessOutcome(mcpOutcome, {
    status: mcpOutcome.status,
    requestId: "req-contended-mcp",
    idempotencyKey: sharedArgs.idempotency_key,
    path: target,
    affectedPaths: [target],
  });
  assert.deepEqual(tickClose, [0, null]);

  const noteOnDisk = await readFile(join(vaultPath, target), "utf8");
  assert.equal(noteOnDisk.match(/^## a1b2c3d4 — contended hook capture$/gm)?.length, 1);
  assert.equal(noteOnDisk.match(/^Contended hook body$/gm)?.length, 1);
});

test("HTTP packaged entrypoint rejects a target swapped to a symlink after validation", async (t) => {
  const { root, vaultPath, cachePath, configPath, httpPath } = await createFixtureVault();
  const pauseDir = join(root, "target-prepare-pause");
  const outsideFile = join(root, "outside-secret.txt");
  const targetPath = join(vaultPath, "Daily", "2026-09-30.md");
  await mkdir(pauseDir);
  await writeFile(outsideFile, "SECRET_DATA");
  const httpServer = startHttpServer(configPath, cachePath, {
    KEEPER_TEST_PAUSE_POINT: "after_target_prepare",
    KEEPER_TEST_PAUSE_DIR: pauseDir,
  }, httpPath);
  t.after(async () => {
    await stopChild(httpServer.child);
    await rm(root, { recursive: true, force: true });
  });

  const http = await initializeHttp(httpServer, 10);
  const call = httpToolCall(http, 11, "obsidian_daily_append", {
    content: "must remain inside the vault",
    section: "## Symlink race",
    date: "2026-09-30",
    idempotency_key: "key-symlink-race",
    request_id: "req-symlink-race",
  });
  await waitForPath(join(pauseDir, "ready"));
  await symlink(outsideFile, targetPath);
  await writeFile(join(pauseDir, "continue"), "continue\n");
  const httpResponse = await call;
  assert.equal(httpResponse.result.isError, true);
  assertFailureOutcome(JSON.parse(httpResponse.result.content[0].text), {
    status: "failed",
    requestId: "req-symlink-race",
    idempotencyKey: "key-symlink-race",
    path: "Daily/2026-09-30.md",
    affectedPaths: ["Daily/2026-09-30.md"],
    errorCode: "WRITE_FAILED",
    detail: "write failed",
    recoveryRequired: true,
    recoveryAction: "retry with the same idempotency_key",
    retryable: true,
  });

  assert.equal(await readFile(outsideFile, "utf8"), "SECRET_DATA");
});

test("stdio server handles simulated partial write fault injection and idempotently recovers", async (t) => {
  const { root, vaultPath, cachePath, configPath, stdioPath } = await createFixtureVault();
  const server = startStdioServer(configPath, cachePath, {
    KEEPER_FAULT_INJECT: "after_note",
    KEEPER_FAULT_MODE: "crash",
  }, stdioPath);

  t.after(async () => {
    await stopChild(server.child);
    await rm(root, { recursive: true, force: true });
  });

  await server.initPromise;

  server.child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "FaultNote", body: "Fault body", idempotency_key: "fault-key-1", request_id: "request-fault-1" },
    },
  })}\n`);
  const firstRes = await server.next(2);
  assert.equal(firstRes.result.isError, true);
  const firstOut = JSON.parse(firstRes.result.content[0].text);
  assertFailureOutcome(firstOut, {
    status: "partial",
    requestId: "request-fault-1",
    idempotencyKey: "fault-key-1",
    path: "Inbox/FaultNote.md",
    affectedPaths: ["Inbox/FaultNote.md", "Inbox/INDEX.md"],
    warnings: ["keeper result was missing or invalid"],
    errorCode: "KEEPER_PROTOCOL_ERROR",
    detail: "keeper result contract failed",
    recoveryRequired: true,
    recoveryAction: "verify affected_paths, then retry with the same idempotency_key",
    retryable: true,
  });
  assert.equal(await readFile(join(vaultPath, "Inbox", "FaultNote.md"), "utf8"), "Fault body");
  await assert.rejects(access(join(vaultPath, "Inbox", "INDEX.md")));

  server.child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "FaultNote", body: "Fault body", idempotency_key: "fault-key-1", request_id: "request-fault-1-retry" },
    },
  })}\n`);
  const retryRes = await server.next(3);
  assert.equal(retryRes.result.isError, false);
  assertSuccessOutcome(responseOutcome(retryRes), {
    status: "committed",
    requestId: "request-fault-1-retry",
    idempotencyKey: "fault-key-1",
    path: "Inbox/FaultNote.md",
    affectedPaths: ["Inbox/FaultNote.md", "Inbox/INDEX.md"],
  });
  assert.equal(await readFile(join(vaultPath, "Inbox", "FaultNote.md"), "utf8"), "Fault body");
  const index = await readFile(join(vaultPath, "Inbox", "INDEX.md"), "utf8");
  assert.equal(index, "# Inbox Index\n- [[Inbox/FaultNote]]\n");
});

test("HTTP packaged entrypoint reports and recovers an after-index partial with a fresh request ID", async (t) => {
  const { root, vaultPath, cachePath, configPath, httpPath } = await createFixtureVault();
  const servers = [];
  t.after(async () => {
    await Promise.all(servers.map((server) => stopChild(server.child)));
    await rm(root, { recursive: true, force: true });
  });

  const faultServer = startHttpServer(configPath, cachePath, { KEEPER_FAULT_INJECT: "after_index" }, httpPath);
  servers.push(faultServer);
  const faultHttp = await initializeHttp(faultServer, 20);
  const firstResponse = await httpToolCall(faultHttp, 21, "obsidian_keeper_save", {
    title: "AfterIndexFault",
    body: "Complete note body",
    idempotency_key: "fault-after-index-key",
    request_id: "fault-after-index-first",
  });
  assert.equal(firstResponse.result.isError, true);
  assertFailureOutcome(JSON.parse(firstResponse.result.content[0].text), {
    status: "partial",
    requestId: "fault-after-index-first",
    idempotencyKey: "fault-after-index-key",
    path: "Inbox/AfterIndexFault.md",
    affectedPaths: ["Inbox/AfterIndexFault.md", "Inbox/INDEX.md"],
    errorCode: "PARTIAL",
    detail: "partial write occurred",
    recoveryRequired: true,
    recoveryAction: "retry with the same idempotency_key",
    retryable: true,
  });
  assert.equal(await readFile(join(vaultPath, "Inbox", "AfterIndexFault.md"), "utf8"), "Complete note body");
  assert.equal(await readFile(join(vaultPath, "Inbox", "INDEX.md"), "utf8"), "# Inbox Index\n- [[Inbox/AfterIndexFault]]\n");

  await stopChild(faultServer.child);
  const recoveryServer = startHttpServer(configPath, cachePath, {}, httpPath);
  servers.push(recoveryServer);
  const recoveryHttp = await initializeHttp(recoveryServer, 22);
  const retryResponse = await httpToolCall(recoveryHttp, 23, "obsidian_keeper_save", {
    title: "AfterIndexFault",
    body: "Complete note body",
    idempotency_key: "fault-after-index-key",
    request_id: "fault-after-index-retry",
  });
  assert.equal(retryResponse.result.isError, false);
  assertSuccessOutcome(responseOutcome(retryResponse), {
    status: "committed",
    requestId: "fault-after-index-retry",
    idempotencyKey: "fault-after-index-key",
    path: "Inbox/AfterIndexFault.md",
    affectedPaths: ["Inbox/AfterIndexFault.md", "Inbox/INDEX.md"],
  });
  assert.equal(await readFile(join(vaultPath, "Inbox", "AfterIndexFault.md"), "utf8"), "Complete note body");
  assert.equal(await readFile(join(vaultPath, "Inbox", "INDEX.md"), "utf8"), "# Inbox Index\n- [[Inbox/AfterIndexFault]]\n");
  assert.deepEqual((await readdir(join(vaultPath, "Inbox"))).sort(), [".INDEX.state", "AfterIndexFault.md", "INDEX.md"]);
});

test("concurrent insert tool calls resolve to one commit and one explicit conflict with Streamable HTTP transport coverage", async (t) => {
  const { root, vaultPath, cachePath, configPath, stdioPath, httpPath } = await createFixtureVault();
  const server = startStdioServer(configPath, cachePath, {}, stdioPath);
  const httpServer = startHttpServer(configPath, cachePath, {}, httpPath);

  t.after(async () => {
    await Promise.all([
      stopChild(server.child),
      stopChild(httpServer.child),
    ]);
    await rm(root, { recursive: true, force: true });
  });

  await server.initPromise;
  const http = await initializeHttp(httpServer, 10);

  const id1 = 2;
  const id2 = 3;

  server.child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: id1, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "SharedTarget", body: "Body 1", idempotency_key: "key-insert-race-a", request_id: "req-race-a" },
    },
  })}\n`);

  const httpCallPromise = httpToolCall(http, id2, "obsidian_keeper_save", {
    title: "SharedTarget",
    body: "Body 2",
    idempotency_key: "key-insert-race-b",
    request_id: "req-race-b",
  });

  const [res1, httpJson] = await Promise.all([server.next(id1), httpCallPromise]);

  const outcome1 = { isError: res1.result.isError, data: JSON.parse(res1.result.content[0].text) };
  const outcome2 = { isError: httpJson.result.isError, data: JSON.parse(httpJson.result.content[0].text) };

  const outcomes = [outcome1, outcome2];
  const committed = outcomes.filter((o) => o.data.status === "committed");
  const conflict = outcomes.filter((o) => o.data.status === "conflict");

  assert.equal(committed.length, 1);
  assert.equal(conflict.length, 1);
  assert.equal(committed[0].isError, false);
  assert.equal(conflict[0].isError, true);
  const expectedByRequest = {
    "req-race-a": { idempotencyKey: "key-insert-race-a", body: "Body 1" },
    "req-race-b": { idempotencyKey: "key-insert-race-b", body: "Body 2" },
  };
  const committedExpected = expectedByRequest[committed[0].data.request_id];
  const conflictExpected = expectedByRequest[conflict[0].data.request_id];
  assert.ok(committedExpected);
  assert.ok(conflictExpected);
  assertSuccessOutcome(committed[0].data, {
    status: "committed",
    requestId: committed[0].data.request_id,
    idempotencyKey: committedExpected.idempotencyKey,
    path: "Inbox/SharedTarget.md",
    affectedPaths: ["Inbox/SharedTarget.md", "Inbox/INDEX.md"],
  });
  assertFailureOutcome(conflict[0].data, {
    status: "conflict",
    requestId: conflict[0].data.request_id,
    idempotencyKey: conflictExpected.idempotencyKey,
    path: "Inbox/SharedTarget.md",
    affectedPaths: ["Inbox/SharedTarget.md", "Inbox/INDEX.md"],
    errorCode: "CONFLICT",
    detail: "write conflict",
    recoveryRequired: false,
    recoveryAction: "",
    retryable: false,
  });

  assert.equal(await readFile(join(vaultPath, "Inbox", "SharedTarget.md"), "utf8"), committedExpected.body);
  const index = await readFile(join(vaultPath, "Inbox", "INDEX.md"), "utf8");
  assert.equal(index, "# Inbox Index\n- [[Inbox/SharedTarget]]\n");
});
