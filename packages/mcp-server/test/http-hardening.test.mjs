import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { access, chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { request as httpRequest } from "node:http";
import { once } from "node:events";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const entrypoint = join(packageRoot, "src", "http.mjs");
const secret = "0123456789abcdef0123456789abcdef";
const issuer = "https://issuer.example";
const audience = "claude-obsidian";

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function token({ exp = Math.floor(Date.now() / 1000) + 300 } = {}) {
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({ aud: audience, exp, iss: issuer, scope: "vault:read repo:read" }));
  const signature = createHmac("sha256", secret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function startServer(configPath, settings = {}) {
  const child = spawn(process.execPath, [entrypoint], {
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
      ...settings,
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
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    const match = stderr.match(/mcp-http-listening (http:\/\/[^\s]+)/);
    if (match) readyResolve(match[1]);
  });
  child.once("error", readyReject);
  child.once("exit", (code, signal) => {
    if (code !== 0) readyReject(new Error(`HTTP server exited before listening: ${code ?? signal}`));
  });
  return {
    child,
    ready,
    stderr: () => stderr,
    async stop() {
      if (child.exitCode === null) child.kill("SIGTERM");
      await Promise.race([once(child, "close").catch(() => {}), new Promise((resolveStop) => setTimeout(resolveStop, 500))]);
    },
  };
}

function headers(url, bearer, extra = {}) {
  return {
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${bearer}`,
    "Content-Type": "application/json",
    Host: new URL(url).host,
    Origin: "https://allowed.example",
    ...extra,
  };
}

function initialize(id = 1) {
  return {
    jsonrpc: "2.0",
    id,
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "http-hardening-test", version: "1.0.0" },
    },
  };
}

async function rawRequest(url, options) {
  const parsed = new URL(url);
  return new Promise((resolveRequest, rejectRequest) => {
    const request = httpRequest({
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname,
      method: options.method,
      headers: options.headers,
    }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.once("end", () => resolveRequest({ status: response.statusCode, body }));
    });
    request.once("error", rejectRequest);
    request.end(options.body);
  });
}

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "mcp-http-hardening-"));
  const vault = join(directory, "vault");
  const config = join(directory, "obsidian.local.md");
  await mkdir(vault);
  await writeFile(join(vault, "note.md"), "# note\n");
  await writeFile(config, `---\nvault_path: ${vault}\n---\n`);
  return { directory, config };
}

test("HTTP hardening covers legacy negotiation, malformed signatures, body limits, cleanup, and expiry", async (t) => {
  const { directory, config } = await fixture();
  const bin = join(directory, "bin");
  const secretMarker = join(bin, "secret-leaked");
  await mkdir(bin);
  await writeFile(join(bin, "bash"), '#!/bin/sh\nif [ -n "${MCP_HTTP_JWT_SECRET+x}" ]; then printf leaked > "$(dirname "$0")/secret-leaked"; fi\nexec /bin/bash "$@"\n');
  await chmod(join(bin, "bash"), 0o755);
  const server = startServer(config, {
    PATH: `${bin}:${process.env.PATH}`,
    MCP_HTTP_CONCURRENCY_LIMIT: "1",
    MCP_HTTP_SESSION_TTL_MS: "100",
  });
  t.after(async () => {
    await server.stop();
    await rm(directory, { recursive: true, force: true });
  });
  const url = await server.ready;
  await assert.rejects(access(secretMarker));
  const validToken = token();

  const malformedSignature = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, `${validToken}=`),
    body: JSON.stringify(initialize()),
  });
  assert.equal(malformedSignature.status, 401);

  const initialized = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken),
    body: JSON.stringify(initialize()),
  });
  assert.equal(initialized.status, 200);
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const capacityRejected = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken),
    body: JSON.stringify(initialize(2)),
  });
  assert.equal(capacityRejected.status, 429);

  const unsupportedModern = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken, { "MCP-Protocol-Version": "2026-07-28", "Mcp-Session-Id": sessionId }),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "server/discover",
      params: {
        _meta: {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": {},
        },
      },
    }),
  });
  assert.equal(unsupportedModern.status, 400);

  const bodyOnGet = await rawRequest(`${url}/mcp`, {
    method: "GET",
    headers: headers(url, validToken, { "Mcp-Session-Id": sessionId, "Content-Length": "4" }),
    body: "body",
  });
  assert.equal(bodyOnGet.status, 400);

  const stream = await fetch(`${url}/mcp`, {
    method: "GET",
    headers: headers(url, validToken, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId }),
  });
  assert.equal(stream.status, 200);
  const closed = await fetch(`${url}/mcp`, {
    method: "DELETE",
    headers: headers(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
  });
  assert.equal(closed.status, 200);
  await stream.body?.cancel();

  const expiring = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken),
    body: JSON.stringify(initialize(3)),
  });
  assert.equal(expiring.status, 200);
  const expiringSession = expiring.headers.get("mcp-session-id");
  assert.ok(expiringSession);
  await new Promise((resolveSleep) => setTimeout(resolveSleep, 180));
  const afterExpiry = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": expiringSession }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 4, method: "tools/list", params: {} }),
  });
  assert.equal(afterExpiry.status, 404);
  assert.match(server.stderr(), /mcp-http-session .*"action":"capacity-rejected".*"reason":"session-cap"/);
  assert.match(server.stderr(), /mcp-http-request .*"status":429.*"rejection_reason":"session-cap"/);
});

test("HTTP session reservations and disconnected stream grace prevent pool exhaustion", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, {
    MCP_HTTP_CONCURRENCY_LIMIT: "1",
    MCP_HTTP_DISCONNECT_GRACE_MS: "100",
  });
  t.after(async () => {
    await server.stop();
    await rm(directory, { recursive: true, force: true });
  });
  const url = await server.ready;
  const validToken = token();
  const responses = await Promise.all(Array.from({ length: 20 }, (_, id) => fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken),
    body: JSON.stringify(initialize(id)),
  })));
  const statuses = responses.map((response) => response.status);
  assert.equal(statuses.filter((status) => status === 200).length, 1);
  assert.equal(statuses.filter((status) => status === 429).length, 19);
  const initialized = responses.find((response) => response.status === 200);
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const stream = await fetch(`${url}/mcp`, {
    method: "GET",
    headers: headers(url, validToken, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId }),
  });
  assert.equal(stream.status, 200);
  await stream.body?.cancel();
  await new Promise((resolveSleep) => setTimeout(resolveSleep, 220));

  const afterDisconnect = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/list", params: {} }),
  });
  assert.equal(afterDisconnect.status, 404);
  assert.match(server.stderr(), /mcp-http-session .*"action":"closed".*"reason":"transport-disconnect"/);
});

test("repeated GET timeouts cannot keep an abandoned session at capacity", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, {
    MCP_HTTP_CONCURRENCY_LIMIT: "1",
    MCP_HTTP_REQUEST_TIMEOUT_MS: "100",
    MCP_HTTP_DISCONNECT_GRACE_MS: "300",
  });
  t.after(async () => {
    await server.stop();
    await rm(directory, { recursive: true, force: true });
  });
  const url = await server.ready;
  const validToken = token();
  const initialized = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken),
    body: JSON.stringify(initialize()),
  });
  assert.equal(initialized.status, 200);
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const stream = await fetch(`${url}/mcp`, {
      method: "GET",
      headers: headers(url, validToken, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId }),
    });
    if (stream.status === 404) break;
    assert.equal(stream.status, 200);
    await stream.text();
  }

  const replacement = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken),
    body: JSON.stringify(initialize(2)),
  });
  assert.equal(replacement.status, 200);
  assert.match(server.stderr(), /mcp-http-session .*"action":"closed".*"reason":"stream-timeout"/);
});

test("a POST after stream timeout retains the active session", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, {
    MCP_HTTP_REQUEST_TIMEOUT_MS: "100",
    MCP_HTTP_DISCONNECT_GRACE_MS: "300",
  });
  t.after(async () => {
    await server.stop();
    await rm(directory, { recursive: true, force: true });
  });
  const url = await server.ready;
  const validToken = token();
  const initialized = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken),
    body: JSON.stringify(initialize()),
  });
  assert.equal(initialized.status, 200);
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const stream = await fetch(`${url}/mcp`, {
    method: "GET",
    headers: headers(url, validToken, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId }),
  });
  assert.equal(stream.status, 200);
  await stream.text();

  const activeHeaders = headers(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId });
  const active = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: activeHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }),
  });
  assert.equal(active.status, 200);
  await new Promise((resolveSleep) => setTimeout(resolveSleep, 350));
  const retained = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: activeHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/list", params: {} }),
  });
  assert.equal(retained.status, 200);

  const deleted = await fetch(`${url}/mcp`, { method: "DELETE", headers: activeHeaders });
  assert.equal(deleted.status, 200);
  const afterDelete = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: activeHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 4, method: "tools/list", params: {} }),
  });
  assert.equal(afterDelete.status, 404);
});

test("a rejected POST does not revive a timed-out session", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, {
    MCP_HTTP_REQUEST_TIMEOUT_MS: "100",
    MCP_HTTP_DISCONNECT_GRACE_MS: "300",
  });
  t.after(async () => {
    await server.stop();
    await rm(directory, { recursive: true, force: true });
  });
  const url = await server.ready;
  const validToken = token();
  const initialized = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, validToken),
    body: JSON.stringify(initialize()),
  });
  assert.equal(initialized.status, 200);
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const stream = await fetch(`${url}/mcp`, {
    method: "GET",
    headers: headers(url, validToken, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId }),
  });
  assert.equal(stream.status, 200);
  await stream.text();

  const sessionHeaders = headers(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId });
  const rejected = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify(initialize(2)),
  });
  assert.equal(rejected.status, 400);

  await new Promise((resolveSleep) => setTimeout(resolveSleep, 350));
  const afterClose = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/list", params: {} }),
  });
  assert.equal(afterClose.status, 404);
});


test("requestEvents waits for newline-complete stderr records", () => {
  let stderr = 'mcp-http-request {"status":200}\nmcp-http-request {"status":';
  const server = { stderr: () => stderr };

  assert.deepEqual(requestEvents(server), [{ status: 200 }]);
  stderr += '408}';
  assert.deepEqual(requestEvents(server), [{ status: 200 }]);
  stderr += '\n';
  assert.deepEqual(requestEvents(server), [{ status: 200 }, { status: 408 }]);
  stderr += 'mcp-http-request {malformed}\n';
  assert.throws(() => requestEvents(server), SyntaxError);
});

function requestEvents(server) {
  return server.stderr().split("\n").slice(0, -1).filter((line) => line.startsWith("mcp-http-request "))
    .map((line) => JSON.parse(line.slice("mcp-http-request ".length)));
}

async function waitForStderr(server, pattern, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pattern.test(server.stderr())) return;
    await new Promise((done) => setTimeout(done, 25));
  }
  assert.fail(`stderr never matched ${pattern}\n${server.stderr()}`);
}

async function waitForRequestEvent(server, predicate) {
  const deadline = Date.now() + 3_000;
  while (Date.now() < deadline) {
    const found = requestEvents(server).find(predicate);
    if (found) return found;
    await new Promise((done) => setTimeout(done, 10));
  }
  assert.fail("expected request telemetry was not emitted");
}

test("request telemetry separates wire status, stream deadline, and client disconnect", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, { MCP_HTTP_REQUEST_TIMEOUT_MS: "400", MCP_HTTP_DISCONNECT_GRACE_MS: "5000" });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, {
    method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()),
  });
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  const ok = await waitForRequestEvent(server, (event) => event.mcp_method === "initialize");
  assert.equal(ok.wire_status, 200);
  assert.equal(ok.terminal_status, 200);
  assert.equal(ok.terminal_reason, "completed");
  assert.equal(ok.timeout_phase, null);
  const streamHeaders = headers(url, bearer, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId });
  const stream = await fetch(`${url}/mcp`, { headers: streamHeaders });
  assert.equal(stream.status, 200);
  await stream.text();
  const timedOut = await waitForRequestEvent(server, (event) => event.method === "GET" && event.timeout_phase === "response_stream");
  assert.equal(timedOut.wire_status, 200);
  assert.equal(timedOut.status, 408); // legacy monitoring contract
  assert.equal(timedOut.terminal_status, 408);
  assert.equal(timedOut.terminal_reason, "request-timeout");
  const disconnected = await fetch(`${url}/mcp`, { headers: streamHeaders });
  assert.equal(disconnected.status, 200);
  await disconnected.body.cancel();
  const cancelled = await waitForRequestEvent(server, (event) => event.terminal_reason === "client-disconnect");
  assert.equal(cancelled.wire_status, 200);
  assert.equal(cancelled.timeout_phase, null);
  assert.equal(cancelled.method, "GET");
  // Request telemetry must not grow a payload, credential, or session identifier channel.
  for (const event of requestEvents(server)) {
    assert.deepEqual(Object.keys(event).sort(), ["event", "method", "status", "wire_status", "terminal_status", "terminal_reason", "timeout_phase", "duration_ms", "mcp_method", "client_id"].sort());
    assert.ok(!JSON.stringify(event).includes(bearer));
    assert.ok(!JSON.stringify(event).includes(sessionId));
  }
});

test("request telemetry identifies an incomplete request body deadline", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, { MCP_HTTP_REQUEST_TIMEOUT_MS: "150" });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const response = await new Promise((resolveResponse, reject) => {
    const request = httpRequest(`${url}/mcp`, {
      method: "POST", headers: headers(url, token(), { "Content-Length": "100" }),
    }, (res) => {
      res.resume();
      res.once("end", () => { request.destroy(); resolveResponse(res.statusCode); });
    });
    request.once("error", reject);
    t.after(() => request.destroy());
    request.write("{"); // Deliberately never finish the declared body.
  });
  assert.equal(response, 408);
  const event = await waitForRequestEvent(server, (item) => item.timeout_phase === "body");
  assert.equal(event.wire_status, 408);
  assert.equal(event.terminal_status, 408);
  assert.equal(event.terminal_reason, "request-timeout");
});

test("request telemetry identifies the transport deadline without logging tool arguments", async (t) => {
  const { directory, config } = await fixture();
  const bin = join(directory, "bin");
  await mkdir(bin);
  // Delay only the real metadata subprocess; configuration resolution stays real.
  await writeFile(join(bin, "bash"), '#!/bin/sh\ncase "$1" in */commit-meta.sh) exec sleep 5 ;; esac\nexec /bin/bash "$@"\n');
  await chmod(join(bin, "bash"), 0o755);
  const server = startServer(config, {
    PATH: `${bin}:${process.env.PATH}`,
    MCP_HTTP_REQUEST_TIMEOUT_MS: "200",
    MCP_REPOSITORY_ROOTS: directory,
  });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, { method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()) });
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  const response = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, bearer, { "Mcp-Session-Id": sessionId, "MCP-Protocol-Version": "2025-11-25" }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "obsidian_commit_meta", arguments: { repository: directory } } }),
  });
  assert.equal(response.status, 408);
  await response.text();
  const event = await waitForRequestEvent(server, (item) => item.tool === "obsidian_commit_meta");
  assert.equal(event.wire_status, 408);
  assert.equal(event.terminal_status, 408);
  assert.equal(event.timeout_phase, "transport");
  assert.equal(event.terminal_reason, "request-timeout");
  assert.ok(!JSON.stringify(event).includes(directory));
  assert.ok(!JSON.stringify(event).includes(bearer));
  assert.ok(!JSON.stringify(event).includes(sessionId));
});

test("disconnect before response headers keeps wire status null", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, { MCP_HTTP_REQUEST_TIMEOUT_MS: "2000" });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const request = httpRequest(`${url}/mcp`, {
    method: "POST", headers: headers(url, token(), { "Content-Length": "100" }),
  });
  request.on("error", () => {});
  t.after(() => request.destroy());
  await new Promise((done) => request.write("{", done));
  // The socket accepted the partial request, then the client leaves before headers.
  await new Promise((done) => setTimeout(done, 50));
  request.destroy();
  const event = await waitForRequestEvent(server, (item) => item.terminal_reason === "client-disconnect");
  assert.equal(event.wire_status, null);
  assert.equal(event.timeout_phase, null);
});

test("concurrent POST tool calls in flight across disconnect grace boundary complete and revive session (#188)", async (t) => {
  const { directory, config } = await fixture();
  const bin = join(directory, "bin");
  await mkdir(bin);
  // Delay commit metadata by 250ms so requests remain in flight when disconnectTimer fires.
  await writeFile(join(bin, "bash"), '#!/bin/sh\ncase "$1" in */commit-meta.sh) node -e \'setTimeout(()=>{}, 250)\' ;; esac\nexec /bin/bash "$@"\n');
  await chmod(join(bin, "bash"), 0o755);
  const server = startServer(config, {
    PATH: `${bin}:${process.env.PATH}`,
    MCP_HTTP_REQUEST_TIMEOUT_MS: "3000",
    MCP_HTTP_DISCONNECT_GRACE_MS: "200",
    MCP_REPOSITORY_ROOTS: directory,
  });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, { method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()) });
  assert.equal(initialized.status, 200);
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const streamHeaders = headers(url, bearer, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId });
  const stream = await fetch(`${url}/mcp`, { headers: streamHeaders });
  assert.equal(stream.status, 200);
  await stream.body.cancel();

  await new Promise((done) => setTimeout(done, 80));

  const sessionHeaders = headers(url, bearer, { "Mcp-Session-Id": sessionId, "MCP-Protocol-Version": "2025-11-25" });
  const calls = Array.from({ length: 4 }, (_, i) => fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 10 + i, method: "tools/call", params: { name: "obsidian_commit_meta", arguments: { repository: directory } } }),
  }));

  const responses = await Promise.all(calls);
  for (const res of responses) {
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.ok(!body.error, `unexpected error: ${JSON.stringify(body.error)}`);
  }

  await new Promise((done) => setTimeout(done, 250));
  const followUp = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 20, method: "tools/list", params: {} }),
  });
  assert.equal(followUp.status, 200);
});

test("rejected POST in flight across disconnect grace boundary does not revive session (#188)", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, {
    MCP_HTTP_REQUEST_TIMEOUT_MS: "2000",
    MCP_HTTP_DISCONNECT_GRACE_MS: "200",
  });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, { method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()) });
  assert.equal(initialized.status, 200);
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const streamHeaders = headers(url, bearer, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId });
  const stream = await fetch(`${url}/mcp`, { headers: streamHeaders });
  assert.equal(stream.status, 200);
  await stream.body.cancel();

  await new Promise((done) => setTimeout(done, 150));

  const payload = '{"jsonrpc":"1.0","id":1}';
  const sessionHeaders = headers(url, bearer, { "Mcp-Session-Id": sessionId, "Content-Length": String(Buffer.byteLength(payload)) });
  const req = httpRequest(`${url}/mcp`, { method: "POST", headers: sessionHeaders });
  const responsePromise = new Promise((resolve) => {
    req.on("response", (res) => {
      let data = "";
      res.on("data", (c) => { data += c; });
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });
  });
  req.write(payload.slice(0, 10));
  await new Promise((done) => setTimeout(done, 300));
  assert.match(server.stderr(), /mcp-http-session .*"action":"disconnect-deferred".*"in_flight":1/);
  assert.doesNotMatch(server.stderr(), /mcp-http-session .*"action":"closed"/);
  const requestEndedAt = Date.now();
  req.end(payload.slice(10));

  const rejected = await responsePromise;
  assert.equal(rejected.status, 400);
  const closedLine = /mcp-http-session .*"action":"closed".*"reason":"transport-disconnect"/;
  for (let waited = 0; waited < 1000 && !closedLine.test(server.stderr()); waited += 25) {
    await new Promise((done) => setTimeout(done, 25));
  }
  assert.match(server.stderr(), closedLine);

  const afterClose = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, bearer, { "Mcp-Session-Id": sessionId, "MCP-Protocol-Version": "2025-11-25" }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 30, method: "tools/list", params: {} }),
  });
  assert.equal(afterClose.status, 404);
});

test("cancelling one of several concurrent POST tool calls leaves its siblings running (#222)", async (t) => {
  const { directory, config } = await fixture();
  const bin = join(directory, "bin");
  await mkdir(bin);
  await writeFile(join(bin, "bash"), '#!/bin/sh\ncase "$1" in */commit-meta.sh) node -e \'setTimeout(()=>{}, 600)\' ;; esac\nexec /bin/bash "$@"\n');
  await chmod(join(bin, "bash"), 0o755);
  const server = startServer(config, {
    PATH: `${bin}:${process.env.PATH}`,
    MCP_HTTP_REQUEST_TIMEOUT_MS: "5000",
    MCP_HTTP_DISCONNECT_GRACE_MS: "5000",
    MCP_REPOSITORY_ROOTS: directory,
  });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, { method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()) });
  assert.equal(initialized.status, 200);
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const sessionHeaders = headers(url, bearer, { "Mcp-Session-Id": sessionId, "MCP-Protocol-Version": "2025-11-25" });
  const call = (id, signal) => fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    signal,
    body: JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name: "obsidian_commit_meta", arguments: { repository: directory } } }),
  });
  const cancelled = new AbortController();
  const cancelledCall = call(10, cancelled.signal).catch((error) => error);
  const siblings = [11, 12, 13].map((id) => call(id));
  await new Promise((done) => setTimeout(done, 150));
  cancelled.abort();

  for (const res of await Promise.all(siblings)) {
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.ok(!body.error, `unexpected error: ${JSON.stringify(body.error)}`);
  }
  assert.equal((await cancelledCall).name, "AbortError");
  assert.equal(server.stderr().match(/"action":"disconnect-deferred"/g)?.length, 1);

  const followUp = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 20, method: "tools/list", params: {} }),
  });
  assert.equal(followUp.status, 200);
});

test("an aborted POST deferred behind an open GET stream closes the session when the stream ends (#222)", async (t) => {
  const { directory, config } = await fixture();
  const bin = join(directory, "bin");
  await mkdir(bin);
  await writeFile(join(bin, "bash"), '#!/bin/sh\ncase "$1" in */commit-meta.sh) node -e \'setTimeout(()=>{}, 300)\' ;; esac\nexec /bin/bash "$@"\n');
  await chmod(join(bin, "bash"), 0o755);
  const server = startServer(config, {
    PATH: `${bin}:${process.env.PATH}`,
    MCP_HTTP_REQUEST_TIMEOUT_MS: "20000",
    MCP_HTTP_DISCONNECT_GRACE_MS: "20000",
    MCP_REPOSITORY_ROOTS: directory,
  });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, { method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()) });
  assert.equal(initialized.status, 200);
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const stream = await fetch(`${url}/mcp`, { headers: headers(url, bearer, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId }) });
  assert.equal(stream.status, 200);

  const sessionHeaders = headers(url, bearer, { "Mcp-Session-Id": sessionId, "MCP-Protocol-Version": "2025-11-25" });
  const cancelled = new AbortController();
  const cancelledCall = fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    signal: cancelled.signal,
    body: JSON.stringify({ jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "obsidian_commit_meta", arguments: { repository: directory } } }),
  }).catch((error) => error);
  await new Promise((done) => setTimeout(done, 100));
  cancelled.abort();
  assert.equal((await cancelledCall).name, "AbortError");

  await waitForStderr(server, /mcp-http-session .*"action":"disconnect-deferred"/);
  await new Promise((done) => setTimeout(done, 500));
  assert.doesNotMatch(server.stderr(), /mcp-http-session .*"action":"closed"/);

  await stream.body.cancel();
  await waitForStderr(server, /mcp-http-session .*"action":"closed"/, 2000);
  const followUp = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 20, method: "tools/list", params: {} }),
  });
  assert.equal(followUp.status, 404);
});

test("POST tool call in flight across session TTL boundary completes and revives session (#221)", async (t) => {
  const { directory, config } = await fixture();
  const bin = join(directory, "bin");
  await mkdir(bin);
  // Delay commit metadata by 350ms so requests remain in flight across the 200ms session TTL boundary.
  await writeFile(join(bin, "bash"), '#!/bin/sh\ncase "$1" in */commit-meta.sh) node -e \'setTimeout(()=>{}, 350)\' ;; esac\nexec /bin/bash "$@"\n');
  await chmod(join(bin, "bash"), 0o755);
  const server = startServer(config, {
    PATH: `${bin}:${process.env.PATH}`,
    MCP_HTTP_REQUEST_TIMEOUT_MS: "3000",
    MCP_HTTP_SESSION_TTL_MS: "200",
    MCP_REPOSITORY_ROOTS: directory,
  });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, { method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()) });
  assert.equal(initialized.status, 200);
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const sessionHeaders = headers(url, bearer, { "Mcp-Session-Id": sessionId, "MCP-Protocol-Version": "2025-11-25" });
  const callPromise = fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "obsidian_commit_meta", arguments: { repository: directory } } }),
  });

  await waitForStderr(server, /mcp-http-session .*"action":"disconnect-deferred".*"reason":"ttl-expired".*"in_flight":1/);
  assert.doesNotMatch(server.stderr(), /mcp-http-session .*"action":"closed"/);

  const res = await callPromise;
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.ok(!body.error, `unexpected error: ${JSON.stringify(body.error)}`);

  const followUp = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 20, method: "tools/list", params: {} }),
  });
  assert.equal(followUp.status, 200);

  await waitForStderr(server, /mcp-http-session .*"action":"closed".*"reason":"ttl-expired"/, 2000);
  const afterClose = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 30, method: "tools/list", params: {} }),
  });
  assert.equal(afterClose.status, 404);
});

test("revived session re-arms idle TTL without a follow-up request (#221)", async (t) => {
  const { directory, config } = await fixture();
  const bin = join(directory, "bin");
  await mkdir(bin);
  await writeFile(join(bin, "bash"), '#!/bin/sh\ncase "$1" in */commit-meta.sh) node -e \'setTimeout(()=>{}, 350)\' ;; esac\nexec /bin/bash "$@"\n');
  await chmod(join(bin, "bash"), 0o755);
  const server = startServer(config, {
    PATH: `${bin}:${process.env.PATH}`,
    MCP_HTTP_REQUEST_TIMEOUT_MS: "3000",
    MCP_HTTP_SESSION_TTL_MS: "200",
    MCP_REPOSITORY_ROOTS: directory,
  });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, { method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()) });
  assert.equal(initialized.status, 200);
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const sessionHeaders = headers(url, bearer, { "Mcp-Session-Id": sessionId, "MCP-Protocol-Version": "2025-11-25" });
  const callPromise = fetch(`${url}/mcp`, {
    method: "POST",
    headers: sessionHeaders,
    body: JSON.stringify({ jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "obsidian_commit_meta", arguments: { repository: directory } } }),
  });
  await waitForStderr(server, /mcp-http-session .*"action":"disconnect-deferred".*"reason":"ttl-expired".*"in_flight":1/);
  const res = await callPromise;
  assert.equal(res.status, 200);
  await res.text();

  await waitForStderr(server, /mcp-http-session .*"action":"closed".*"reason":"ttl-expired"/, 2000);
});

test("rejected POST in flight across session TTL boundary does not revive session (#221)", async (t) => {
  const { directory, config } = await fixture();
  const server = startServer(config, {
    MCP_HTTP_REQUEST_TIMEOUT_MS: "2000",
    MCP_HTTP_SESSION_TTL_MS: "200",
  });
  t.after(async () => { await server.stop(); await rm(directory, { recursive: true, force: true }); });
  const url = await server.ready;
  const bearer = token();
  const initialized = await fetch(`${url}/mcp`, { method: "POST", headers: headers(url, bearer), body: JSON.stringify(initialize()) });
  assert.equal(initialized.status, 200);
  await initialized.text();
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);

  const payload = '{"jsonrpc":"1.0","id":1}';
  const sessionHeaders = headers(url, bearer, { "Mcp-Session-Id": sessionId, "Content-Length": String(Buffer.byteLength(payload)) });
  const req = httpRequest(`${url}/mcp`, { method: "POST", headers: sessionHeaders });
  const responsePromise = new Promise((resolve) => {
    req.on("response", (res) => {
      let data = "";
      res.on("data", (c) => { data += c; });
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });
  });
  req.write(payload.slice(0, 10));
  await waitForStderr(server, /mcp-http-session .*"action":"disconnect-deferred".*"reason":"ttl-expired".*"in_flight":1/);
  assert.doesNotMatch(server.stderr(), /mcp-http-session .*"action":"closed"/);
  const requestEndedAt = Date.now();
  req.end(payload.slice(10));

  const rejected = await responsePromise;
  assert.equal(rejected.status, 400);

  await waitForStderr(server, /mcp-http-session .*"action":"closed".*"reason":"ttl-expired"/, 2000);
  // A revived session would only close after a fresh 200ms idle TTL; a rejected one closes on drain.
  assert.ok(Date.now() - requestEndedAt < 150);

  const afterClose = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: headers(url, bearer, { "Mcp-Session-Id": sessionId, "MCP-Protocol-Version": "2025-11-25" }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 30, method: "tools/list", params: {} }),
  });
  assert.equal(afterClose.status, 404);
});
