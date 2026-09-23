import assert from "node:assert/strict";
import { access, mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
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

async function createFixtureVault(dailyPath = "Daily") {
  const root = await mkdtemp(join(tmpdir(), "mcp-write-test-"));
  const vaultPath = join(root, "vault");
  const configDir = join(root, "config");
  await mkdir(vaultPath, { recursive: true });
  await mkdir(join(vaultPath, dailyPath), { recursive: true });
  await mkdir(join(vaultPath, "Inbox"), { recursive: true });
  await mkdir(join(vaultPath, "Projects"), { recursive: true });
  await mkdir(configDir, { recursive: true });

  const configPath = join(configDir, "obsidian.local.md");
  const configContent = `---
vault_path: ${vaultPath}
daily_path: ${dailyPath}/
---

## Project Taxonomy
| Domain | Path | Keywords |
|---|---|---|
| Development | Projects/Development/ | dev, code |
`;
  await writeFile(configPath, configContent, "utf8");
  return { root, vaultPath, configPath };
}

function assertFailedWriteEnvelope(outcome, errorCode) {
  assert.equal(outcome.status, "failed");
  assert.equal(typeof outcome.request_id, "string");
  assert.equal(typeof outcome.idempotency_key, "string");
  assert.equal(typeof outcome.path, "string");
  assert.ok(Array.isArray(outcome.affected_paths));
  assert.ok(Array.isArray(outcome.warnings));
  assert.equal(typeof outcome.recovery?.required, "boolean");
  assert.equal(typeof outcome.recovery?.action, "string");
  assert.equal(outcome.error_code, errorCode);
  assert.equal(typeof outcome.retryable, "boolean");
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

async function holdKeeperLock(vaultPath, root, label) {
  const pauseDir = join(root, `pause-${label}`);
  await mkdir(pauseDir);
  const child = spawn("bash", [join(repositoryRoot, "scripts", "keeper"), "append", "--vault", vaultPath, "--target", `Hold/${label}.md`], {
    env: { ...process.env, KEEPER_TEST_PAUSE_POINT: "after_lock_owner", KEEPER_TEST_PAUSE_DIR: pauseDir },
    stdio: ["pipe", "ignore", "pipe"],
  });
  child.stdin.end("lock holder\n");
  await waitForPath(join(pauseDir, "ready"));
  return {
    child,
    async release() {
      await writeFile(join(pauseDir, "continue"), "continue\n");
      await once(child, "close");
    },
  };
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
      arguments: { title: "Test Note", body: "Sample body content", folder_hint: "Inbox", idempotency_key: "save-1", request_id: "request-save-1" },
    },
  }, 2);

  assert.equal(saveResponse.jsonrpc, "2.0");
  assert.equal(saveResponse.id, 2);
  assert.equal(saveResponse.result.isError, false);
  const data = JSON.parse(saveResponse.result.content[0].text);
  assert.equal(data.status, "committed");
  assert.equal(data.path, "Inbox/Test Note.md");
  assert.equal(data.request_id, "request-save-1");
  assert.equal(data.idempotency_key, "save-1");
  assert.deepEqual(data.affected_paths, ["Inbox/Test Note.md", "Inbox/INDEX.md"]);

  const replay = await server.request({
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Test Note", body: "Sample body content", folder_hint: "Inbox", idempotency_key: "save-1", request_id: "request-save-2" },
    },
  }, 3);
  assert.equal(replay.result.isError, false);
  assert.equal(replay.result.structuredContent.status, "skipped");
  assert.equal(replay.result.structuredContent.request_id, "request-save-2");

  const conflict = await server.request({
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Test Note", body: "Different content", folder_hint: "Inbox", idempotency_key: "save-1" },
    },
  }, 4);
  assert.equal(conflict.result.isError, true);
  const conflictData = JSON.parse(conflict.result.content[0].text);
  assert.equal(conflictData.status, "conflict");
  assert.equal(conflictData.code, "IDEMPOTENCY_CONFLICT");

  const localWithoutKey = await server.request({
    jsonrpc: "2.0",
    id: 5,
    method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "No Key", body: "Rejected" } },
  }, 5);
  assert.equal(localWithoutKey.result.isError, false);
  assert.equal(localWithoutKey.result.structuredContent.status, "committed");
  assert.equal(localWithoutKey.result.structuredContent.idempotency_key, "");
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
      arguments: { content: "First commit log entry", section: `## ${sha} — msg`, date: "2026-09-22", skip_if_hash: sha, idempotency_key: "daily-1" },
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
      arguments: { content: "First commit log entry", section: `## ${sha} — msg`, date: "2026-09-22", skip_if_hash: sha, idempotency_key: "daily-1" },
    },
  }, 3);
  assert.equal(second.result.isError, false);
  assert.equal(JSON.parse(second.result.content[0].text).status, "skipped");

  const conflict = await server.request({
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "Different entry", section: `## ${sha} — msg`, date: "2026-09-22", skip_if_hash: sha, idempotency_key: "daily-1" },
    },
  }, 4);
  assert.equal(conflict.result.isError, true);
  assert.equal(JSON.parse(conflict.result.content[0].text).code, "IDEMPOTENCY_CONFLICT");
});

test("stdio daily append uses configured daily_path and reports the written path", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault("Journal/Days");
  const server = startStdioServer(configPath);
  t.after(async () => {
    if (!server.child.killed) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const response = await server.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "obsidian_daily_append", arguments: { content: "Configured path", date: "2026-09-23", idempotency_key: "configured-daily-1" } },
  }, 2);
  assert.equal(response.result.isError, false);
  assert.equal(response.result.structuredContent.path, "Journal/Days/2026-09-23.md");
  assert.match(await readFile(join(vaultPath, "Journal", "Days", "2026-09-23.md"), "utf8"), /Configured path/);
  await assert.rejects(readFile(join(vaultPath, "Daily", "2026-09-23.md"), "utf8"));
});

test("stdio writes fail with a structured configuration error when daily_path is missing or invalid", async (t) => {
  for (const scenario of [
    { name: "missing", replace: "", requestId: "missing-daily-path" },
    { name: "invalid", replace: "daily_path: ../Outside/\n", requestId: "invalid-daily-path" },
  ]) {
    await t.test(scenario.name, async () => {
      const { root, vaultPath, configPath } = await createFixtureVault();
      const config = await readFile(configPath, "utf8");
      await writeFile(configPath, config.replace(/^daily_path:.*\n/m, scenario.replace), "utf8");
      const server = startStdioServer(configPath);
      try {
        await server.request({
          jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
        }, 1);
        server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
        const response = await server.request({
          jsonrpc: "2.0", id: 2, method: "tools/call",
          params: {
            name: "obsidian_daily_append",
            arguments: {
              content: "Must not use a fallback",
              date: "2026-09-26",
              request_id: scenario.requestId,
              idempotency_key: `${scenario.name}-daily-key`,
            },
          },
        }, 2);

        assert.equal(response.result.isError, true);
        const outcome = JSON.parse(response.result.content[0].text);
        assert.equal(outcome.code, "CONFIG_INVALID");
        assertFailedWriteEnvelope(outcome, "CONFIG_INVALID");
        assert.equal(outcome.request_id, scenario.requestId);
        assert.equal(outcome.idempotency_key, `${scenario.name}-daily-key`);
        assert.equal(outcome.path, "");
        assert.deepEqual(outcome.affected_paths, []);
        await assert.rejects(readFile(join(vaultPath, "Daily", "2026-09-26.md"), "utf8"));
      } finally {
        if (!server.child.killed) server.child.stdin.end();
        await once(server.child, "close").catch(() => {});
        await rm(root, { recursive: true, force: true });
      }
    });
  }
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
      arguments: { title: "Bad Note", body: "Escaping", folder_hint: "../../outside", idempotency_key: "traversal-1" },
    },
  }, 2);

  assert.equal(traversalResponse.result.isError, true);
  const error = JSON.parse(traversalResponse.result.content[0].text);
  assert.equal(error.code, "PATH_INVALID");
  assertFailedWriteEnvelope(error, "PATH_INVALID");
  assert.equal(error.idempotency_key, "traversal-1");
});

test("stdio preserves recoverable partial keeper outcomes", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  await mkdir(join(vaultPath, "Blocked", "INDEX.md"), { recursive: true });
  const server = startStdioServer(configPath);
  t.after(async () => {
    if (!server.child.killed) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const response = await server.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Needs Recovery", body: "Written before INDEX failure", folder_hint: "Blocked", idempotency_key: "partial-1" },
    },
  }, 2);
  assert.equal(response.result.isError, true);
  const outcome = JSON.parse(response.result.content[0].text);
  assert.equal(outcome.status, "partial");
  assert.equal(outcome.code, "PARTIAL");
  assert.equal(outcome.recovery.required, true);
  assert.equal(outcome.retryable, true);
  assert.deepEqual(outcome.affected_paths, ["Blocked/Needs Recovery.md", "Blocked/INDEX.md"]);
  assert.match(await readFile(join(vaultPath, "Blocked", "Needs Recovery.md"), "utf8"), /Written before INDEX failure/);
});

test("stdio recovers an insert when the keeper dies after writing the note", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const crashServer = startStdioServer(configPath, { KEEPER_FAULT_INJECT: "after_note", KEEPER_FAULT_MODE: "crash" });
  let recoveryServer;
  t.after(async () => {
    for (const server of [crashServer, recoveryServer]) {
      if (!server) continue;
      if (!server.child.killed) server.child.stdin.end();
      await once(server.child, "close").catch(() => {});
    }
    await rm(root, { recursive: true, force: true });
  });

  await crashServer.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  crashServer.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const crashed = await crashServer.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Crash Recovery", body: "Written before keeper death", idempotency_key: "crash-insert-1", request_id: "crash-insert-request" },
    },
  }, 2);
  const crashedOutcome = JSON.parse(crashed.result.content[0].text);
  assert.equal(crashed.result.isError, true);
  assert.equal(crashedOutcome.code, "KEEPER_PROTOCOL_ERROR");
  assert.equal(crashedOutcome.status, "partial");
  assert.equal(crashedOutcome.recovery.required, true);
  assert.equal(crashedOutcome.retryable, true);
  assert.match(await readFile(join(vaultPath, "Inbox", "Crash Recovery.md"), "utf8"), /Written before keeper death/);

  crashServer.child.stdin.end();
  await once(crashServer.child, "close");
  recoveryServer = startStdioServer(configPath);
  await recoveryServer.request({
    jsonrpc: "2.0", id: 3, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 3);
  recoveryServer.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const recovered = await recoveryServer.request({
    jsonrpc: "2.0", id: 4, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Crash Recovery", body: "Written before keeper death", idempotency_key: "crash-insert-1", request_id: "crash-insert-retry" },
    },
  }, 4);
  assert.equal(recovered.result.isError, false);
  assert.equal(recovered.result.structuredContent.status, "committed");
  assert.match(await readFile(join(vaultPath, "Inbox", "INDEX.md"), "utf8"), /Crash Recovery/);
});

test("stdio recovers an append when the keeper dies after writing the section", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const crashServer = startStdioServer(configPath, { KEEPER_FAULT_INJECT: "after_append", KEEPER_FAULT_MODE: "crash" });
  let recoveryServer;
  t.after(async () => {
    for (const server of [crashServer, recoveryServer]) {
      if (!server) continue;
      if (!server.child.killed) server.child.stdin.end();
      await once(server.child, "close").catch(() => {});
    }
    await rm(root, { recursive: true, force: true });
  });

  await crashServer.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  crashServer.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const crashed = await crashServer.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "Append written before keeper death", section: "## Crash Append", date: "2026-09-23", idempotency_key: "crash-append-1", request_id: "crash-append-request" },
    },
  }, 2);
  const crashedOutcome = JSON.parse(crashed.result.content[0].text);
  assert.equal(crashed.result.isError, true);
  assert.equal(crashedOutcome.code, "KEEPER_PROTOCOL_ERROR");
  assert.equal(crashedOutcome.status, "partial");
  assert.equal(crashedOutcome.recovery.required, true);
  assert.equal(crashedOutcome.retryable, true);

  crashServer.child.stdin.end();
  await once(crashServer.child, "close");
  recoveryServer = startStdioServer(configPath);
  await recoveryServer.request({
    jsonrpc: "2.0", id: 3, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 3);
  recoveryServer.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const recovered = await recoveryServer.request({
    jsonrpc: "2.0", id: 4, method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "Append written before keeper death", section: "## Crash Append", date: "2026-09-23", idempotency_key: "crash-append-1", request_id: "crash-append-retry" },
    },
  }, 4);
  assert.equal(recovered.result.isError, false);
  assert.equal(recovered.result.structuredContent.status, "skipped");
  const note = await readFile(join(vaultPath, "Daily", "2026-09-23.md"), "utf8");
  assert.equal(note.match(/^## Crash Append$/gm)?.length, 1);
});

test("stdio timeout and cancellation never report false write success and keep same-key retry safe", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath);
  let holder;
  t.after(async () => {
    if (holder?.child.exitCode === null) holder.child.kill("SIGKILL");
    if (!server.child.killed) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });

  await server.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });

  holder = await holdKeeperLock(vaultPath, root, "timeout");
  const timedOut = await server.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Timed Out", body: "Timeout body", idempotency_key: "timeout-1", request_id: "timeout-request" },
    },
  }, 2);
  assert.equal(timedOut.result.isError, true);
  const timeoutOutcome = JSON.parse(timedOut.result.content[0].text);
  assert.equal(timeoutOutcome.code, "SUBPROCESS_TIMEOUT");
  assert.equal(timeoutOutcome.status, "failed");
  assert.equal(timeoutOutcome.recovery.required, true);
  assert.equal(timeoutOutcome.retryable, true);
  assert.deepEqual(timeoutOutcome.affected_paths, ["Inbox/Timed Out.md", "Inbox/INDEX.md"]);
  await holder.release();

  holder = await holdKeeperLock(vaultPath, root, "cancel");
  const cancelled = server.request({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Cancelled", body: "Cancellation body", idempotency_key: "cancel-1", request_id: "cancel-request" },
    },
  }, 3);
  const cancelledHandled = cancelled.catch(() => {});
  await new Promise((resolveWait) => setTimeout(resolveWait, 100));
  server.notification({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3, reason: "test" } });
  await new Promise((resolveWait) => setTimeout(resolveWait, 150));
  await holder.release();

  const retried = await server.request({
    jsonrpc: "2.0", id: 4, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Cancelled", body: "Cancellation body", idempotency_key: "cancel-1", request_id: "cancel-retry" },
    },
  }, 4);
  assert.equal(retried.result.isError, false);
  assert.equal(retried.result.structuredContent.status, "committed");
  assert.match(await readFile(join(vaultPath, "Inbox", "Cancelled.md"), "utf8"), /Cancellation body/);
  await cancelledHandled;
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

  const listedReadTools = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(readOnlyToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": readSessionId }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 10, method: "tools/list", params: {} }),
  });
  const readToolNames = (await listedReadTools.json()).result.tools.map((tool) => tool.name).sort();
  assert.deepEqual(readToolNames, ["obsidian_commit_meta", "obsidian_find_notes"]);

  // Read-only token write attempt -> 403 Forbidden
  const writeAttemptForbidden = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(readOnlyToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": readSessionId }),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "obsidian_daily_append", arguments: { content: "Forbidden write", idempotency_key: "forbidden-1" } },
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

  const listedWriteTools = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(writeToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": writeSessionId }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 11, method: "tools/list", params: {} }),
  });
  const writeToolNames = (await listedWriteTools.json()).result.tools.map((tool) => tool.name).sort();
  assert.deepEqual(writeToolNames, ["obsidian_daily_append", "obsidian_find_notes", "obsidian_keeper_save"]);

  const missingRemoteKey = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(writeToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": writeSessionId }),
    body: JSON.stringify({
      jsonrpc: "2.0", id: 12, method: "tools/call",
      params: { name: "obsidian_daily_append", arguments: { content: "Missing key" } },
    }),
  });
  const missingRemoteResult = await missingRemoteKey.json();
  assert.equal(missingRemoteResult.result.isError, true);
  const missingRemoteOutcome = JSON.parse(missingRemoteResult.result.content[0].text);
  assert.equal(missingRemoteOutcome.code, "INVALID_INPUT");
  assertFailedWriteEnvelope(missingRemoteOutcome, "INVALID_INPUT");
  assert.equal(missingRemoteOutcome.idempotency_key, "");
  assert.match(missingRemoteOutcome.path, /^Daily\/\d{4}-\d{2}-\d{2}\.md$/);

  // Write token write call -> 200 Success
  const writeAllowed = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(writeToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": writeSessionId }),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "obsidian_daily_append", arguments: { content: "Authorized HTTP entry", date: "2026-09-22", idempotency_key: "http-daily-1" } },
    }),
  });
  assert.equal(writeAllowed.status, 200);
  const writeResult = await writeAllowed.json();
  assert.equal(writeResult.result.isError, false);
  assert.equal(JSON.parse(writeResult.result.content[0].text).status, "committed");
});
