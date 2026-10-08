import assert from "node:assert/strict";
import { access, mkdtemp, readdir, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import { createHmac } from "node:crypto";
import { writeOutput } from "../src/stdio.mjs";

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

const writeTools = new Set(["obsidian_keeper_save", "obsidian_daily_append"]);

// Every write outcome the adapter returns must satisfy its own output schema,
// refinements included, so contract drift fails the test that produced it.
function assertWriteContract(message, response) {
  if (message.method !== "tools/call" || !writeTools.has(message.params?.name)) return;
  const outcome = response.result?.structuredContent;
  if (!outcome) return;
  const result = writeOutput.safeParse(outcome);
  assert.ok(result.success, `write outcome breaks its contract: ${JSON.stringify(result.error?.issues)} ${JSON.stringify(outcome)}`);
}

function startStdioServer(configPath, extraEnv = {}) {
  const child = spawn(process.execPath, [stdioEntrypoint], {
    cwd: tmpdir(),
    env: { ...process.env, OBSIDIAN_LOCAL_MD: configPath, MCP_REPOSITORY_ROOTS: repositoryRoot, MCP_STDIO_PROFILE: "write", ...extraEnv },
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
    async request(message, id, waitMs = 8000) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
      for (;;) {
        if (childError) throw childError;
        const response = messages.find((candidate) => candidate.id === id);
        if (response) {
          assertWriteContract(message, response);
          return response;
        }
        await Promise.race([
          new Promise((resolveWait) => {
            messageWaiter = resolveWait;
          }),
          new Promise((_, reject) => {
            setTimeout(() => reject(new Error(`timed out waiting for MCP response ${id}`)), waitMs);
          }),
        ]);
      }
    },
    notification(message) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    },
  };
}

function startHttpServer(configPath, extraEnv = {}) {
  const child = spawn(process.execPath, [httpEntrypoint], {
    cwd: tmpdir(),
    env: {
      ...process.env,
      ...extraEnv,
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

  return { child, ready, stderr: () => stderr };
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
      arguments: { title: "Test Note", body: "Sample body content", resolved: true, folder_hint: "Inbox", idempotency_key: "save-1", request_id: "request-save-1" },
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
      arguments: { title: "Test Note", body: "Sample body content", resolved: true, folder_hint: "Inbox", idempotency_key: "save-1", request_id: "request-save-2" },
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
      arguments: { title: "Test Note", body: "Different content", resolved: true, folder_hint: "Inbox", idempotency_key: "save-1" },
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
    params: { name: "obsidian_keeper_save", arguments: { title: "No Key", body: "Rejected", resolved: true, folder_hint: "Inbox" } },
  }, 5);
  assert.equal(localWithoutKey.result.isError, false);
  assert.equal(localWithoutKey.result.structuredContent.status, "committed");
  assert.equal(localWithoutKey.result.structuredContent.idempotency_key, "");
});

test("stdio keeper save enforces resolved target semantics and input limits", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
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

  const missingResolved = await server.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Missing Resolved", body: "must be rejected", resolved: false, folder_hint: "Inbox" } },
  }, 2);
  const missingResolvedOutcome = JSON.parse(missingResolved.result.content[0].text);
  assert.equal(missingResolved.result.isError, true);
  assert.equal(missingResolvedOutcome.code, "INVALID_INPUT");
  await assert.rejects(access(join(vaultPath, "Inbox", "Missing Resolved.md")));

  const omittedResolved = await server.request({
    jsonrpc: "2.0", id: 7, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Omitted Resolved", body: "must be rejected", folder_hint: "Inbox" } },
  }, 7);
  const omittedResolvedOutcome = JSON.parse(omittedResolved.result.content[0].text);
  assert.equal(omittedResolved.result.isError, true);
  assert.equal(omittedResolvedOutcome.code, "INVALID_INPUT");
  await assert.rejects(access(join(vaultPath, "Inbox", "Omitted Resolved.md")));

  const exactBody = await server.request({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Exact Body", body: "x".repeat(65536), resolved: true, folder_hint: "Inbox", idempotency_key: "exact-body" } },
  }, 3);
  assert.equal(exactBody.result.isError, false);

  const excessiveBody = await server.request({
    jsonrpc: "2.0", id: 4, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Excessive Body", body: "x".repeat(65537), resolved: true, folder_hint: "Inbox", idempotency_key: "excessive-body" } },
  }, 4);
  const excessiveBodyOutcome = JSON.parse(excessiveBody.result.content[0].text);
  assert.equal(excessiveBody.result.isError, true);
  assert.equal(excessiveBodyOutcome.code, "INVALID_INPUT");
  await assert.rejects(access(join(vaultPath, "Inbox", "Excessive Body.md")));

  const exactLinks = await server.request({
    jsonrpc: "2.0", id: 5, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Exact Links", body: "links", resolved: true, folder_hint: "Inbox", links: Array.from({ length: 20 }, (_, index) => `[[Link ${index}]]`), idempotency_key: "exact-links" } },
  }, 5);
  assert.equal(exactLinks.result.isError, false);

  const excessiveLinks = await server.request({
    jsonrpc: "2.0", id: 6, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Excessive Links", body: "links", resolved: true, folder_hint: "Inbox", links: Array.from({ length: 21 }, (_, index) => `[[Link ${index}]]`), idempotency_key: "excessive-links" } },
  }, 6);
  const excessiveLinksOutcome = JSON.parse(excessiveLinks.result.content[0].text);
  assert.equal(excessiveLinks.result.isError, true);
  assert.equal(excessiveLinksOutcome.code, "INVALID_INPUT");
  await assert.rejects(access(join(vaultPath, "Inbox", "Excessive Links.md")));
});

test("stdio keeper save preserves committed status while surfacing lock release warnings", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath, { KEEPER_TEST_LOCK_RELEASE_FAIL: "1" });

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
    params: { name: "obsidian_keeper_save", arguments: { title: "Release Warning", body: "saved", resolved: true, folder_hint: "Inbox", idempotency_key: "release-warning" } },
  }, 2);
  assert.equal(response.result.isError, false);
  assert.equal(response.result.structuredContent.status, "committed");
  assert.match(response.result.structuredContent.warnings.join(" "), /lock release failed/);
  assert.match(await readFile(join(vaultPath, "Inbox", "Release Warning.md"), "utf8"), /saved/);
});

test("stdio keeper save does not require daily_path", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const config = await readFile(configPath, "utf8");
  await writeFile(configPath, config.replace(/^daily_path:.*\n/m, ""), "utf8");
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
      arguments: {
        title: "No Daily Path",
        body: "Independent keeper save",
        resolved: true,
        folder_hint: "Inbox",
        type: 'note: "quoted"',
        links: ["[[Daily: 2026-09-22]]", "tag: value"],
        idempotency_key: "save-without-daily-path",
      },
    },
  }, 2);

  assert.equal(response.result.isError, false);
  assert.equal(response.result.structuredContent.status, "committed");
  assert.equal(response.result.structuredContent.path, "Inbox/No Daily Path.md");
  const savedNote = await readFile(join(vaultPath, "Inbox", "No Daily Path.md"), "utf8");
  assert.ok(savedNote.includes('type: "note: \\"quoted\\""'));
  assert.ok(savedNote.includes('links: "[[Daily: 2026-09-22]], tag: value"'));
  assert.match(savedNote, /Independent keeper save/);
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

test("stdio daily append takes an exact target_path with a hash gate, and keeper save links the daily note (#162)", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
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
  const call = (id, name, args) => server.request({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } }, id);

  const target = "Projects/Development/nhangen/demo/2026-10-08.md";
  const first = await call(2, "obsidian_daily_append", { content: "- first commit", section: "abc1234 first commit", target_path: target, skip_if_hash: "abc1234" });
  assert.equal(first.result.isError, false);
  assert.equal(first.result.structuredContent.path, target);
  const second = await call(3, "obsidian_daily_append", { content: "- first commit", section: "abc1234 first commit", target_path: target, skip_if_hash: "abc1234" });
  assert.equal(second.result.isError, false);
  const written = await readFile(join(vaultPath, target), "utf8");
  assert.equal(written.split("abc1234 first commit").length - 1, 1, "hash gate must not append the same commit twice");
  await assert.rejects(readFile(join(vaultPath, "Daily", "2026-10-08.md"), "utf8"));

  for (const [id, bad] of [[4, { target_path: "../escape.md" }], [5, { target_path: "Projects/note.txt" }], [6, { target_path: target, date: "2026-10-08" }]]) {
    const rejected = await call(id, "obsidian_daily_append", { content: "x", ...bad });
    assert.equal(rejected.result.isError, true, JSON.stringify(bad));
  }

  const saved = await call(7, "obsidian_keeper_save", {
    title: "Linked session", body: "Body", resolved: true, folder_hint: "Inbox", session_link_date: "2026-10-08",
  });
  assert.equal(saved.result.isError, false);
  assert.match(await readFile(join(vaultPath, "Daily", "2026-10-08.md"), "utf8"), /Linked session/);
});

test("target_path ignores a bad daily_path but session_link_date requires a valid one (#162)", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  await writeFile(configPath, (await readFile(configPath, "utf8")).replace(/^daily_path:.*$/m, "daily_path: ../escape/"), "utf8");
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
  const call = (id, name, args) => server.request({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } }, id);
  const ok = await call(2, "obsidian_daily_append", { content: "x", target_path: "Projects/a.md" });
  assert.equal(ok.result.isError, false);
  assert.equal(ok.result.structuredContent.path, "Projects/a.md");
  const bad = await call(3, "obsidian_keeper_save", { title: "T", body: "b", resolved: true, folder_hint: "Inbox", session_link_date: "2026-10-08" });
  assert.equal(bad.result.isError, true);
  assert.equal(bad.result.structuredContent.error_code, "CONFIG_INVALID");
  const abs = await call(4, "obsidian_daily_append", { content: "x", target_path: "/etc/x.md" });
  assert.equal(abs.result.isError, true);
});

test("find_notes matches every term of a multi-word query, not the whole phrase (#162)", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath);
  t.after(async () => {
    if (!server.child.killed) server.child.stdin.end();
    await once(server.child, "close").catch(() => {});
    await rm(root, { recursive: true, force: true });
  });
  await writeFile(join(vaultPath, "Projects", "TypeSafe outage.md"), "The obsidian mcp skill was down.\n", "utf8");
  await writeFile(join(vaultPath, "Projects", "Other.md"), "typesafe only here\n", "utf8");
  await server.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const found = await server.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "obsidian_find_notes", arguments: { query: "typesafe skill obsidian mcp outage" } },
  }, 2);
  assert.deepEqual(found.result.structuredContent.matches.map((match) => match.path), ["Projects/TypeSafe outage.md"]);
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

  const missingFolderResponse = await server.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Missing Folder", body: "must be rejected", resolved: true, idempotency_key: "missing-folder" },
    },
  }, 2);
  const missingFolderError = JSON.parse(missingFolderResponse.result.content[0].text);
  assert.equal(missingFolderError.code, "INVALID_INPUT");

  const absoluteFolderResponse = await server.request({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Absolute Folder", body: "must be rejected", resolved: true, folder_hint: "/Inbox", idempotency_key: "absolute-folder" },
    },
  }, 3);
  const absoluteFolderError = JSON.parse(absoluteFolderResponse.result.content[0].text);
  assert.equal(absoluteFolderError.code, "PATH_INVALID");

  const traversalResponse = await server.request({
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Bad Note", body: "Escaping", resolved: true, folder_hint: "../../outside", idempotency_key: "traversal-1" },
    },
  }, 4);

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
      arguments: { title: "Needs Recovery", body: "Written before INDEX failure", resolved: true, folder_hint: "Blocked", idempotency_key: "partial-1" },
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
      if (server.child.exitCode === null) {
        server.child.stdin.end();
        await once(server.child, "close").catch(() => {});
      }
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
      arguments: { title: "Crash Recovery", body: "Written before keeper death", resolved: true, folder_hint: "Inbox", idempotency_key: "crash-insert-1", request_id: "crash-insert-request" },
    },
  }, 2);
  const crashedOutcome = JSON.parse(crashed.result.content[0].text);
  assert.equal(crashed.result.isError, true);
  assert.equal(crashedOutcome.code, "KEEPER_PROTOCOL_ERROR");
  assert.equal(crashedOutcome.status, "partial");
  assert.equal(crashedOutcome.recovery.required, true);
  assert.equal(crashedOutcome.retryable, true);
  // The keeper died after the note: its progress markers still name what is left.
  assert.match(crashedOutcome.warnings.join(" "), /exited without a result after the note was written to Inbox\/Crash Recovery\.md; unfinished: INDEX and idempotency record/);
  assert.match(crashedOutcome.recovery.action, /^do not rewrite the note; retry with the same idempotency_key to finish INDEX/);
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
      arguments: { title: "Crash Recovery", body: "Written before keeper death", resolved: true, folder_hint: "Inbox", idempotency_key: "crash-insert-1", request_id: "crash-insert-retry" },
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
      if (server.child.exitCode === null) {
        server.child.stdin.end();
        await once(server.child, "close").catch(() => {});
      }
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

test("stdio does not skip a pending append that matches content from another key", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const firstServer = startStdioServer(configPath);
  let crashServer;
  let recoveryServer;
  t.after(async () => {
    for (const server of [firstServer, crashServer, recoveryServer]) {
      if (!server) continue;
      if (server.child.exitCode === null) {
        server.child.stdin.end();
        await once(server.child, "close").catch(() => {});
      }
    }
    await rm(root, { recursive: true, force: true });
  });

  await firstServer.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  firstServer.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const first = await firstServer.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "Same content", section: "## Same Section", date: "2026-09-23", idempotency_key: "other-key", request_id: "other-request" },
    },
  }, 2);
  assert.equal(first.result.isError, false);
  assert.equal(first.result.structuredContent.status, "committed");
  firstServer.child.stdin.end();
  await once(firstServer.child, "close");

  crashServer = startStdioServer(configPath, { KEEPER_FAULT_INJECT: "before_append", KEEPER_FAULT_MODE: "crash" });
  await crashServer.request({
    jsonrpc: "2.0", id: 3, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 3);
  crashServer.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const crashed = await crashServer.request({
    jsonrpc: "2.0", id: 4, method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "Same content", section: "## Same Section", date: "2026-09-23", idempotency_key: "new-key", request_id: "new-request" },
    },
  }, 4);
  assert.equal(crashed.result.isError, true);
  assert.equal(JSON.parse(crashed.result.content[0].text).status, "partial");
  crashServer.child.stdin.end();
  await once(crashServer.child, "close");

  recoveryServer = startStdioServer(configPath);
  await recoveryServer.request({
    jsonrpc: "2.0", id: 5, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 5);
  recoveryServer.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const recovered = await recoveryServer.request({
    jsonrpc: "2.0", id: 6, method: "tools/call",
    params: {
      name: "obsidian_daily_append",
      arguments: { content: "Same content", section: "## Same Section", date: "2026-09-23", idempotency_key: "new-key", request_id: "new-retry" },
    },
  }, 6);
  assert.equal(recovered.result.isError, false);
  assert.equal(recovered.result.structuredContent.status, "committed");
  const note = await readFile(join(vaultPath, "Daily", "2026-09-23.md"), "utf8");
  assert.equal(note.match(/^## Same Section$/gm)?.length, 2);
});

test("stdio timeout and cancellation never report false write success and keep same-key retry safe", async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  const server = startStdioServer(configPath, { MCP_KEEPER_SAVE_TIMEOUT_MS: "1000" });
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
      arguments: { title: "Timed Out", body: "Timeout body", resolved: true, folder_hint: "Inbox", idempotency_key: "timeout-1", request_id: "timeout-request" },
    },
  }, 2);
  assert.equal(timedOut.result.isError, true);
  const timeoutOutcome = JSON.parse(timedOut.result.content[0].text);
  assert.equal(timeoutOutcome.code, "SUBPROCESS_TIMEOUT");
  assert.equal(timeoutOutcome.status, "partial");
  assert.equal(timeoutOutcome.recovery.required, true);
  assert.equal(timeoutOutcome.retryable, true);
  assert.deepEqual(timeoutOutcome.affected_paths, ["Inbox/Timed Out.md", "Inbox/INDEX.md"]);
  await holder.release();

  const timeoutRetry = await server.request({
    jsonrpc: "2.0", id: 5, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Timed Out", body: "Timeout body", resolved: true, folder_hint: "Inbox", idempotency_key: "timeout-1", request_id: "timeout-retry" },
    },
  }, 5);
  assert.equal(timeoutRetry.result.isError, false);
  assert.equal(timeoutRetry.result.structuredContent.status, "committed");

  holder = await holdKeeperLock(vaultPath, root, "timeout-keyless");
  const keylessTimedOut = await server.request({
    jsonrpc: "2.0", id: 6, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Keyless Timeout", body: "Keyless timeout body", resolved: true, folder_hint: "Inbox", request_id: "keyless-timeout" },
    },
  }, 6);
  assert.equal(keylessTimedOut.result.isError, true);
  const keylessTimeoutOutcome = JSON.parse(keylessTimedOut.result.content[0].text);
  assert.equal(keylessTimeoutOutcome.code, "SUBPROCESS_TIMEOUT");
  assert.equal(keylessTimeoutOutcome.retryable, false);
  assert.equal(keylessTimeoutOutcome.recovery.required, false);
  assert.equal(keylessTimeoutOutcome.recovery.action, "");
  assert.match(keylessTimeoutOutcome.warnings.join(" "), /may have committed/);
  await holder.release();

  holder = await holdKeeperLock(vaultPath, root, "cancel");
  const cancelled = server.request({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Cancelled", body: "Cancellation body", resolved: true, folder_hint: "Inbox", idempotency_key: "cancel-1", request_id: "cancel-request" },
    },
  }, 3);
  const cancelledHandled = cancelled.catch(() => {});
  await new Promise((resolveWait) => setTimeout(resolveWait, 100));
  server.notification({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3, reason: "test" } });
  await new Promise((resolveWait) => setTimeout(resolveWait, 150));
  await holder.release();
  await assert.rejects(access(join(vaultPath, "Inbox", "Cancelled.md")));

  const retried = await server.request({
    jsonrpc: "2.0", id: 4, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Cancelled", body: "Cancellation body", resolved: true, folder_hint: "Inbox", idempotency_key: "cancel-1", request_id: "cancel-retry" },
    },
  }, 4);
  assert.equal(retried.result.isError, false);
  assert.equal(retried.result.structuredContent.status, "committed");
  assert.match(await readFile(join(vaultPath, "Inbox", "Cancelled.md"), "utf8"), /Cancellation body/);
  await cancelledHandled;

  holder = await holdKeeperLock(vaultPath, root, "cancel-timeout");
  const timedOutAgain = await server.request({
    jsonrpc: "2.0", id: 7, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Timed Out Again", body: "Timeout body", resolved: true, folder_hint: "Inbox", idempotency_key: "timeout-2", request_id: "timeout-request-2" },
    },
  }, 7);
  assert.equal(timedOutAgain.result.isError, true);
  assert.equal(JSON.parse(timedOutAgain.result.content[0].text).code, "SUBPROCESS_TIMEOUT");
  await holder.release();
  const timeoutRetryAgain = await server.request({
    jsonrpc: "2.0", id: 8, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Timed Out Again", body: "Timeout body", resolved: true, folder_hint: "Inbox", idempotency_key: "timeout-2", request_id: "timeout-retry-2" },
    },
  }, 8);
  assert.equal(timeoutRetryAgain.result.isError, false);
  assert.equal(timeoutRetryAgain.result.structuredContent.status, "committed");
});

// End a server and wait for it, killing it if it does not exit in time, so a
// failed assertion never leaves a child that keeps the test run alive.
async function stopChild(child, { graceful = (c) => c.stdin?.end(), waitMs = 5_000 } = {}) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const closed = once(child, "close").catch(() => {});
  graceful(child);
  const timer = setTimeout(() => child.kill("SIGKILL"), waitMs);
  await closed;
  clearTimeout(timer);
}

// The close of a child that is expected to exit on its own, or a failure (not
// a hang) when it does not.
async function closeWithin(child, waitMs, label) {
  let timer;
  const timedOut = new Promise((resolveTimeout) => { timer = setTimeout(resolveTimeout, waitMs, "timeout"); });
  const result = await Promise.race([once(child, "close"), timedOut]);
  clearTimeout(timer);
  if (result === "timeout") {
    child.kill("SIGKILL");
    assert.fail(`${label}: still running after ${waitMs} ms`);
  }
  return result;
}

// A keeper hung inside its lock leaves that vault's lock to the stale reaper
// (two seconds), so each hung-keeper case gets a vault of its own, and the
// caps leave room for a loaded machine to reach the step under test.
async function hungKeeperSave(t, { fault, title, idempotencyKey, env = {}, waitMs = 30_000 }) {
  const fixture = await createFixtureVault();
  const server = startStdioServer(fixture.configPath, { KEEPER_FAULT_INJECT: fault, KEEPER_FAULT_MODE: "hang", MCP_KEEPER_SAVE_TIMEOUT_MS: "4000", ...env });
  t.after(async () => {
    await stopChild(server.child);
    await rm(fixture.root, { recursive: true, force: true });
  });
  await server.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const started = Date.now();
  const response = await server.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title, body: `${title} body`, resolved: true, folder_hint: "Inbox", request_id: `${title.replace(/ /g, "-")}-request`, ...(idempotencyKey ? { idempotency_key: idempotencyKey } : {}) },
    },
  }, 2, waitMs);
  const elapsed = Date.now() - started;
  assert.equal(response.result.isError, true);
  return { fixture, server, response, elapsed, outcome: JSON.parse(response.result.content[0].text) };
}

test("MCP_KEEPER_SAVE_TIMEOUT_MS is the cap a keeper save runs under", { timeout: 30_000 }, async (t) => {
  // The other two caps are far out of reach: a save that used either one
  // would outlast the 10 s wait and fail here.
  const { outcome, elapsed } = await hungKeeperSave(t, {
    fault: "after_note", title: "Capped Save", idempotencyKey: "capped-1", waitMs: 10_000,
    env: { MCP_KEEPER_SAVE_TIMEOUT_MS: "1500", MCP_DAILY_APPEND_TIMEOUT_MS: "60000", MCP_COMMIT_META_TIMEOUT_MS: "60000" },
  });
  assert.equal(outcome.code, "SUBPROCESS_TIMEOUT");
  assert.ok(elapsed >= 1_200 && elapsed <= 6_000, `keeper save stopped after ${elapsed} ms, not near its 1500 ms cap`);
});

test("stdio keeper save that times out after the note is written names the unfinished steps and the cap to raise", { timeout: 60_000 }, async (t) => {
  const { fixture, response, outcome } = await hungKeeperSave(t, { fault: "after_note", title: "Slow Index", idempotencyKey: "slow-index-1" });
  assert.equal(outcome.code, "SUBPROCESS_TIMEOUT");
  assert.equal(outcome.status, "partial");
  assert.equal(outcome.error_code, "SUBPROCESS_TIMEOUT");
  // Keyed: the same key recovers the written note, so the outcome stays
  // retryable, but only after the cap is raised.
  assert.equal(outcome.retryable, true);
  assert.equal(outcome.recovery.required, true);
  assert.equal(outcome.recovery.action, "do not rewrite the note; raise MCP_KEEPER_SAVE_TIMEOUT_MS, then retry with the same idempotency_key to finish INDEX and idempotency record (retry with the same idempotency_key)");
  assert.ok(outcome.warnings.includes("keeper write timed out after the note was written to Inbox/Slow Index.md; unfinished: INDEX and idempotency record (retry with the same idempotency_key)"), outcome.warnings.join(" | "));
  assert.ok(outcome.warnings.includes("raise MCP_KEEPER_SAVE_TIMEOUT_MS before retrying; the same cap would stop the retry at the same step"));
  assert.doesNotMatch(outcome.warnings.join(" "), /Session Link/);
  assert.deepEqual(outcome.affected_paths, ["Inbox/Slow Index.md", "Inbox/INDEX.md"]);
  assert.deepEqual(response.result.structuredContent, Object.fromEntries(Object.entries(outcome).filter(([key]) => !["code", "detail"].includes(key))));
  assert.match(await readFile(join(fixture.vaultPath, "Inbox", "Slow Index.md"), "utf8"), /Slow Index body/);

  // With the cap lifted, the same key finishes the INDEX step without a second note.
  const healthy = startStdioServer(fixture.configPath, { MCP_KEEPER_SAVE_TIMEOUT_MS: "25000" });
  t.after(() => stopChild(healthy.child));
  await healthy.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  healthy.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const finished = await healthy.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "obsidian_keeper_save",
      arguments: { title: "Slow Index", body: "Slow Index body", resolved: true, folder_hint: "Inbox", idempotency_key: "slow-index-1", request_id: "slow-index-retry" },
    },
  }, 2, 30_000);
  assert.equal(finished.result.isError, false, finished.result.content[0].text);
  assert.equal(finished.result.structuredContent.status, "committed");
  assert.match(await readFile(join(fixture.vaultPath, "Inbox", "INDEX.md"), "utf8"), /\[\[(?:Inbox\/)?Slow Index\]\]/);
});

test("stdio keyless keeper save that times out after the note is written fails without advertising a retry", { timeout: 60_000 }, async (t) => {
  const { outcome } = await hungKeeperSave(t, { fault: "after_note", title: "Slow Keyless" });
  assert.equal(outcome.code, "SUBPROCESS_TIMEOUT");
  assert.equal(outcome.status, "failed");
  assert.equal(outcome.retryable, false);
  assert.equal(outcome.recovery.required, true);
  assert.equal(outcome.recovery.action, "do not rewrite the note; finish INDEX for Inbox/Slow Keyless.md manually");
  // Keyless: the idempotency record is a no-op, so it is not a pending step.
  assert.ok(outcome.warnings.includes("keeper write timed out after the note was written to Inbox/Slow Keyless.md; unfinished: INDEX"), outcome.warnings.join(" | "));
  assert.match(outcome.warnings.join(" "), /no idempotency key/);
});

test("stdio keyless keeper save stopped after INDEX says nothing known is unfinished", { timeout: 60_000 }, async (t) => {
  const { outcome } = await hungKeeperSave(t, { fault: "after_index", title: "Slow Keyless Index" });
  assert.equal(outcome.status, "failed");
  assert.equal(outcome.retryable, false);
  assert.equal(outcome.recovery.action, "do not rewrite the note; nothing known unfinished; verify Inbox/Slow Keyless Index.md and INDEX");
  assert.ok(outcome.warnings.includes("keeper write timed out after the note was written to Inbox/Slow Keyless Index.md; nothing known unfinished"), outcome.warnings.join(" | "));
});

test("stdio keeper save that times out after INDEX names the idempotency record as unfinished", { timeout: 60_000 }, async (t) => {
  const { fixture, outcome } = await hungKeeperSave(t, { fault: "after_index", title: "Slow Record", idempotencyKey: "slow-record-1" });
  assert.equal(outcome.code, "SUBPROCESS_TIMEOUT");
  assert.equal(outcome.status, "partial");
  assert.equal(outcome.retryable, true);
  assert.ok(outcome.warnings.includes("keeper write timed out after the note was written to Inbox/Slow Record.md; unfinished: idempotency record (retry with the same idempotency_key)"), outcome.warnings.join(" | "));
  assert.equal(outcome.recovery.action, "do not rewrite the note; raise MCP_KEEPER_SAVE_TIMEOUT_MS, then retry with the same idempotency_key to finish idempotency record (retry with the same idempotency_key)");
  assert.match(await readFile(join(fixture.vaultPath, "Inbox", "INDEX.md"), "utf8"), /\[\[(?:Inbox\/)?Slow Record\]\]/);
});

test("a keeper save cancelled after its note is written leaves one note that the same key completes", { timeout: 60_000 }, async (t) => {
  const fixture = await createFixtureVault();
  const hung = startStdioServer(fixture.configPath, { KEEPER_FAULT_INJECT: "after_note", KEEPER_FAULT_MODE: "hang", MCP_KEEPER_SAVE_TIMEOUT_MS: "60000" });
  t.after(async () => {
    await stopChild(hung.child);
    await rm(fixture.root, { recursive: true, force: true });
  });
  await hung.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  hung.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const pending = hung.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Cancelled Late", body: "Cancelled late body", resolved: true, folder_hint: "Inbox", idempotency_key: "cancel-late-1", request_id: "cancel-late" } },
  }, 2, 60_000);
  pending.catch(() => {});
  // Wait until the note is on disk, then cancel while the keeper hangs before INDEX.
  await waitForPath(join(fixture.vaultPath, "Inbox", "Cancelled Late.md"));
  hung.notification({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 2, reason: "test" } });
  await stopChild(hung.child);

  // MCP sends no response to a cancelled request, so the outcome is checked
  // through what a same-key retry finds: one note, completed, linked once.
  const retry = startStdioServer(fixture.configPath, { MCP_KEEPER_SAVE_TIMEOUT_MS: "25000" });
  t.after(() => stopChild(retry.child));
  await retry.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  retry.notification({ jsonrpc: "2.0", method: "notifications/initialized" });
  const retried = await retry.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Cancelled Late", body: "Cancelled late body", resolved: true, folder_hint: "Inbox", idempotency_key: "cancel-late-1", request_id: "cancel-late-retry" } },
  }, 2, 30_000);
  assert.equal(retried.result.isError, false, retried.result.content[0].text);
  assert.equal(retried.result.structuredContent.status, "committed");
  const inbox = (await readdir(join(fixture.vaultPath, "Inbox"))).filter((name) => name.startsWith("Cancelled Late"));
  assert.deepEqual(inbox, ["Cancelled Late.md"]);
  const index = await readFile(join(fixture.vaultPath, "Inbox", "INDEX.md"), "utf8");
  assert.equal(index.match(/Cancelled Late\]\]/g)?.length, 1, index);
});

test("stdio rejects malformed and out-of-range subprocess timeout settings", { timeout: 60_000 }, async (t) => {
  const { root, configPath } = await createFixtureVault();
  const children = [];
  t.after(async () => {
    for (const child of children) await stopChild(child);
    await rm(root, { recursive: true, force: true });
  });
  for (const name of ["MCP_KEEPER_SAVE_TIMEOUT_MS", "MCP_DAILY_APPEND_TIMEOUT_MS", "MCP_COMMIT_META_TIMEOUT_MS"]) {
    for (const [value, message] of [["5s", "must be an integer"], ["-1", "must be an integer"], ["99", "is outside its allowed range"], ["600001", "is outside its allowed range"]]) {
      const server = startStdioServer(configPath, { [name]: value });
      children.push(server.child);
      // An accepted value would leave the server waiting on stdin: fail, not hang.
      const [code] = await closeWithin(server.child, 5_000, `${name}=${value}`);
      assert.notEqual(code, 0, `${name}=${value}`);
      assert.match(server.stderr(), new RegExp(`${name} ${message}`), `${name}=${value}`);
    }
    for (const value of ["100", "600000"]) {
      const server = startStdioServer(configPath, { [name]: value });
      children.push(server.child);
      const response = await server.request({
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
      }, 1);
      assert.ok(response.result, `${name}=${value}`);
      await stopChild(server.child);
    }
  }
});

test("MCP_DAILY_APPEND_TIMEOUT_MS caps daily appends independently of the other caps", { timeout: 60_000 }, async (t) => {
  const { root, vaultPath, configPath } = await createFixtureVault();
  // The other caps are far out of reach, so only the daily cap can end the append.
  const server = startStdioServer(configPath, { MCP_DAILY_APPEND_TIMEOUT_MS: "500", MCP_KEEPER_SAVE_TIMEOUT_MS: "60000", MCP_COMMIT_META_TIMEOUT_MS: "60000" });
  let holder;
  t.after(async () => {
    if (holder?.child.exitCode === null) holder.child.kill("SIGKILL");
    await stopChild(server.child);
    await rm(root, { recursive: true, force: true });
  });
  await server.request({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
  }, 1);
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });

  holder = await holdKeeperLock(vaultPath, root, "daily-cap");
  const started = Date.now();
  const daily = await server.request({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "obsidian_daily_append", arguments: { content: "Capped", date: "2026-09-24", idempotency_key: "daily-cap-1", request_id: "daily-cap" } },
  }, 2);
  assert.equal(JSON.parse(daily.result.content[0].text).code, "SUBPROCESS_TIMEOUT");
  assert.ok(Date.now() - started < 3_000, `daily append took ${Date.now() - started} ms, not near its 500 ms cap`);

  // The keeper-save cap is separate: a save started under the same held lock
  // waits it out and commits once the lock is released.
  const save = server.request({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: { name: "obsidian_keeper_save", arguments: { title: "Waited", body: "Waited body", resolved: true, folder_hint: "Inbox", idempotency_key: "waited-1", request_id: "waited" } },
  }, 3, 30_000);
  await new Promise((resolveWait) => setTimeout(resolveWait, 1_000));
  await holder.release();
  const saved = await save;
  assert.equal(saved.result.isError, false, saved.result.content[0].text);
  assert.equal(saved.result.structuredContent.status, "committed");
});

test("HTTP warns at startup when any subprocess cap is not below the request timeout", { timeout: 60_000 }, async (t) => {
  const { root, configPath } = await createFixtureVault();
  const children = [];
  t.after(async () => {
    for (const child of children) await stopChild(child, { graceful: (c) => c.kill("SIGTERM") });
    await rm(root, { recursive: true, force: true });
  });
  // Every cap is checked, not only the keeper save.
  {
    const server = startHttpServer(configPath, { MCP_HTTP_REQUEST_TIMEOUT_MS: "8000" });
    children.push(server.child);
    await server.ready;
    assert.match(server.stderr(), /mcp-http-warning MCP_KEEPER_SAVE_TIMEOUT_MS \(25000\)/);
    assert.match(server.stderr(), /mcp-http-warning MCP_DAILY_APPEND_TIMEOUT_MS \(10000\)/);
    assert.doesNotMatch(server.stderr(), /mcp-http-warning MCP_COMMIT_META_TIMEOUT_MS/);
    await stopChild(server.child, { graceful: (c) => c.kill("SIGTERM") });
  }
  for (const [env, warned] of [
    [{ MCP_HTTP_REQUEST_TIMEOUT_MS: "1000" }, true],
    // The termination grace counts: 29600 ms + 500 ms reaches a 30000 ms request.
    [{ MCP_HTTP_REQUEST_TIMEOUT_MS: "30000", MCP_KEEPER_SAVE_TIMEOUT_MS: "29600" }, true],
    [{ MCP_HTTP_REQUEST_TIMEOUT_MS: "30000", MCP_KEEPER_SAVE_TIMEOUT_MS: "29400" }, false],
    [{}, false],
  ]) {
    const server = startHttpServer(configPath, env);
    children.push(server.child);
    await server.ready;
    const warning = /mcp-http-warning MCP_KEEPER_SAVE_TIMEOUT_MS \(\d+\) plus the 500 ms termination grace is not below MCP_HTTP_REQUEST_TIMEOUT_MS/;
    if (warned) assert.match(server.stderr(), warning, JSON.stringify(env));
    else assert.doesNotMatch(server.stderr(), /mcp-http-warning/);
    await stopChild(server.child, { graceful: (c) => c.kill("SIGTERM") });
  }
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
