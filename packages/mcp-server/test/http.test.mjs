import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createHmac } from "node:crypto";
import { request as httpRequest } from "node:http";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const entrypoint = join(packageRoot, "src", "http.mjs");
const secret = "0123456789abcdef0123456789abcdef";
const issuer = "https://issuer.example";
const audience = "claude-obsidian";

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function token({ scope = "vault:read repo:read", exp = Math.floor(Date.now() / 1000) + 300, aud = audience, iss = issuer, sub = "http-contract-test" } = {}) {
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({ aud, exp, iss, scope, sub }));
  const signature = createHmac("sha256", secret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function startServer(configPath) {
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
      MCP_HTTP_MAX_BODY_BYTES: "2048",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolveReady, rejectReady) => {
    readyResolve = resolveReady;
    readyReject = rejectReady;
  });
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
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
    stdout: () => stdout,
    stderr: () => stderr,
    async stop() {
      if (child.exitCode === null) child.kill("SIGTERM");
      await Promise.race([once(child, "close").catch(() => {}), new Promise((resolveStop) => setTimeout(resolveStop, 500))]);
    },
  };
}

function requestHeaders(url, bearer, extra = {}) {
  const host = new URL(url).host;
  return {
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${bearer}`,
    "Content-Type": "application/json",
    Host: host,
    Origin: "https://allowed.example",
    ...extra,
  };
}

function initializeRequest(id = 1) {
  return {
    jsonrpc: "2.0",
    id,
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "http-contract-test", version: "1.0.0" },
    },
  };
}

function rawRequest(url, options) {
  const parsed = new URL(url);
  return new Promise((resolveRequest, rejectRequest) => {
    const request = httpRequest(
      {
        hostname: parsed.hostname,
        port: parsed.port,
        path: parsed.pathname,
        method: options.method,
        headers: options.headers,
      },
      (response) => {
        response.resume();
        response.once("end", () => resolveRequest({ status: response.statusCode, headers: response.headers }));
      },
    );
    request.once("error", rejectRequest);
    request.end(options.body);
  });
}

test("authenticated Streamable HTTP is read-only and enforces transport boundaries", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-http-"));
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(vault);
  await writeFile(join(vault, "remote-note.md"), "# Remote MCP note\nThis is readable over HTTP.\n");
  await writeFile(config, `---\nvault_path: ${vault}\n---\n`);

  const server = startServer(config);
  t.after(async () => {
    await server.stop();
    await rm(fixture, { recursive: true, force: true });
  });
  const url = await server.ready;
  const validToken = token();

  const unauthenticated = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, "", { Authorization: undefined }),
    body: JSON.stringify(initializeRequest()),
  });
  assert.equal(unauthenticated.status, 401);
  assert.doesNotMatch(await unauthenticated.text(), /Bearer|0123456789/);

  const invalidOrigin = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken, { Origin: "https://evil.example" }),
    body: JSON.stringify(initializeRequest()),
  });
  assert.equal(invalidOrigin.status, 403);

  const invalidHost = await rawRequest(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken, { Host: "evil.example" }),
    body: JSON.stringify(initializeRequest()),
  });
  assert.equal(invalidHost.status, 403);

  const expired = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, token({ exp: Math.floor(Date.now() / 1000) - 1 })),
    body: JSON.stringify(initializeRequest()),
  });
  assert.equal(expired.status, 401);

  const wrongAudience = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, token({ aud: "wrong-audience" })),
    body: JSON.stringify(initializeRequest()),
  });
  assert.equal(wrongAudience.status, 401);

  const insufficientScope = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, token({ scope: "other:scope" })),
    body: JSON.stringify(initializeRequest()),
  });
  assert.equal(insufficientScope.status, 403);

  const queryCredential = await fetch(`${url}/mcp?access_token=${encodeURIComponent(validToken)}`, {
    method: "POST",
    headers: requestHeaders(url, "", { Authorization: undefined }),
    body: JSON.stringify(initializeRequest()),
  });
  assert.equal(queryCredential.status, 400);

  const repositoryOnlyToken = token({ scope: "repo:read" });
  const repositoryOnlyInitialized = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, repositoryOnlyToken),
    body: JSON.stringify(initializeRequest(11)),
  });
  assert.equal(repositoryOnlyInitialized.status, 200);
  const repositoryOnlySessionId = repositoryOnlyInitialized.headers.get("mcp-session-id");
  assert.ok(repositoryOnlySessionId);

  const deniedPrompts = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, repositoryOnlyToken, {
      "MCP-Protocol-Version": "2025-11-25",
      "Mcp-Session-Id": repositoryOnlySessionId,
    }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 12, method: "prompts/list", params: {} }),
  });
  assert.equal(deniedPrompts.status, 403);

  const initialized = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken),
    body: JSON.stringify(initializeRequest()),
  });
  assert.equal(initialized.status, 200);
  assert.match(initialized.headers.get("content-type") ?? "", /application\/json/);
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.ok(sessionId);
  assert.equal((await initialized.json()).result.protocolVersion, "2025-11-25");

  const listed = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }),
  });
  assert.equal(listed.status, 200);
  const toolNames = (await listed.json()).result.tools.map((tool) => tool.name).sort();
  assert.deepEqual(toolNames, ["obsidian_commit_meta", "obsidian_find_notes"]);

  const prompts = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
    body: JSON.stringify({ jsonrpc: "2.0", id: 21, method: "prompts/list", params: {} }),
  });
  assert.equal(prompts.status, 200);
  const promptNames = (await prompts.json()).result.prompts.map((prompt) => prompt.name).sort();
  assert.deepEqual(promptNames, ["ask_vault_librarian", "summarize_session"]);

  for (const [id, name, args] of [
    [22, "ask_vault_librarian", { query: "remote compatibility" }],
    [23, "summarize_session", { transcript: "{\"type\":\"user\",\"message\":{\"content\":\"Summarize this compatibility check.\"}}" }],
  ]) {
    const retrievedPrompt = await fetch(`${url}/mcp`, {
      method: "POST",
      headers: requestHeaders(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
      body: JSON.stringify({ jsonrpc: "2.0", id, method: "prompts/get", params: { name, arguments: args } }),
    });
    assert.equal(retrievedPrompt.status, 200);
    const result = await retrievedPrompt.json();
    assert.equal(result.id, id);
    assert.equal(result.result.messages.length, 1);
  }

  const search = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "obsidian_find_notes", arguments: { query: "remote" } },
    }),
  });
  assert.equal(search.status, 200);
  assert.equal((await search.json()).result.structuredContent.matches[0].path, "remote-note.md");

  const beforeMutationAttempt = await readFile(join(vault, "remote-note.md"), "utf8");
  const unavailableMutation = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 31,
      method: "tools/call",
      params: { name: "obsidian_insert_note", arguments: { target: "remote-note.md", body: "changed" } },
    }),
  });
  assert.equal(unavailableMutation.status, 200);
  assert.ok((await unavailableMutation.json()).error);
  assert.equal(await readFile(join(vault, "remote-note.md"), "utf8"), beforeMutationAttempt);

  const malformed = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
    body: "not-json",
  });
  assert.equal(malformed.status, 400);

  const oversized = await fetch(`${url}/mcp`, {
    method: "POST",
    headers: requestHeaders(url, validToken, { "Mcp-Session-Id": sessionId }),
    body: "x".repeat(4096),
  });
  assert.equal(oversized.status, 413);

  const stream = await fetch(`${url}/mcp`, {
    method: "GET",
    headers: requestHeaders(url, validToken, { Accept: "text/event-stream", "Mcp-Session-Id": sessionId }),
  });
  assert.equal(stream.status, 200);
  assert.match(stream.headers.get("content-type") ?? "", /text\/event-stream/);
  await stream.body?.cancel();

  const unsupported = await fetch(`${url}/mcp`, {
    method: "PUT",
    headers: requestHeaders(url, validToken, { "Mcp-Session-Id": sessionId }),
    body: JSON.stringify(initializeRequest(4)),
  });
  assert.equal(unsupported.status, 405);
  assert.match(unsupported.headers.get("allow") ?? "", /GET/);

  const closed = await fetch(`${url}/mcp`, {
    method: "DELETE",
    headers: requestHeaders(url, validToken, { "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId }),
  });
  assert.equal(closed.status, 200);

  assert.equal(server.stdout(), "");
  const requestEvents = server.stderr()
    .split("\n")
    .filter((line) => line.startsWith("mcp-http-request "))
    .map((line) => JSON.parse(line.slice("mcp-http-request ".length)));
  const sessionEvents = server.stderr()
    .split("\n")
    .filter((line) => line.startsWith("mcp-http-session "))
    .map((line) => JSON.parse(line.slice("mcp-http-session ".length)));
  assert.ok(requestEvents.some((event) => event.status === 200 && event.mcp_method === "initialize"));
  assert.ok(requestEvents.some((event) => event.status === 200 && event.mcp_method === "tools/call" && event.tool === "obsidian_find_notes"));
  assert.ok(requestEvents.some((event) => event.status === 401 && event.client_id === "unknown"));
  assert.ok(requestEvents.every((event) => Number.isInteger(event.duration_ms) && event.duration_ms >= 0));
  assert.ok(requestEvents.some((event) => event.client_id === "http-contract-test"));
  assert.ok(sessionEvents.some((event) => event.action === "created" && event.client_id === "http-contract-test"));
  assert.ok(sessionEvents.some((event) => event.action === "initialized" && event.session_id !== "pending"));
  assert.ok(sessionEvents.some((event) => event.action === "closed" && event.reason === "client-delete"));
  assert.ok(sessionEvents.every((event) => event.session_id.length <= 12 && event.auth_fingerprint.length <= 12));
  assert.doesNotMatch(server.stderr(), new RegExp(secret));
  assert.doesNotMatch(server.stderr(), /remote compatibility|changed/);
});

test("usage aggregation ignores malformed and unstructured journal lines", async () => {
  const { aggregateUsage } = await import("../monitor.mjs");
  const output = [
    "unrelated line",
    'mcp-http-request {"status":200,"duration_ms":10,"client_id":"codex","tool":"obsidian_find_notes"}',
    'mcp-http-request {"status":403,"duration_ms":30,"client_id":"unknown"}',
    'mcp-http-request {"method":"GET","status":408,"duration_ms":999999,"client_id":"codex"}',
    'mcp-http-request {"status":429,"duration_ms":2,"client_id":"codex","rejection_reason":"active-stream-cap"}',
    "mcp-http-request not-json",
    'mcp-http-request {"status":200,"duration_ms":20,"client_id":"claude"}',
  ].join("\n");
  assert.deepEqual(aggregateUsage(output), {
    requests: 5,
    successful_requests: 2,
    failed_requests: 3,
    tool_calls: 1,
    stream_requests: 1,
    clients: ["claude", "codex", "unknown"],
    p95_duration_ms: 30,
    rejection_reasons: { "active-stream-cap": 1 },
  });
});

test("session telemetry aggregation reports lifecycle pressure without secrets", async () => {
  const { aggregateSessionTelemetry } = await import("../monitor.mjs");
  const output = [
    'mcp-http-session {"action":"created","active_sessions":1}',
    'mcp-http-session {"action":"initialized","active_sessions":1}',
    'mcp-http-session {"action":"capacity-rejected","reason":"session-cap","active_sessions":64}',
    'mcp-http-session {"action":"closed","reason":"ttl-expired","active_sessions":63}',
    "mcp-http-session not-json",
  ].join("\n");
  assert.deepEqual(aggregateSessionTelemetry(output), {
    events: 4,
    created: 1,
    initialized: 1,
    touched: 0,
    closed: 1,
    "transport-disconnect": 0,
    "capacity-rejected": 1,
    max_active_sessions: 64,
    current_active_sessions: 63,
    close_reasons: { "ttl-expired": 1 },
  });
});

test("monitor retains usage telemetry when health is unavailable", async () => {
  const { collectState } = await import("../monitor.mjs");
  const state = await collectState({
    healthCheck: async () => { throw new Error("health HTTP 429"); },
    usageReader: async () => ({
      window_minutes: 15,
      sessions: { "capacity-rejected": 2, current_active_sessions: 64 },
    }),
  });
  assert.equal(state.status, "failed");
  assert.equal(state.error, "health HTTP 429");
  assert.deepEqual(state.sessions, { "capacity-rejected": 2, current_active_sessions: 64 });
});

test("monitor CLI runs through the deployed current symlink", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-monitor-"));
  const link = join(fixture, "monitor.mjs");
  await symlink(join(packageRoot, "monitor.mjs"), link);
  t.after(() => rm(fixture, { recursive: true, force: true }));
  const child = spawn(process.execPath, [link], {
    env: Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("MCP_HTTP_"))),
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  const [code] = await once(child, "close");
  assert.equal(code, 1);
  assert.match(stderr, /MCP_HTTP_JWT_SECRET is required/);
});

test("monitor health check requests the Streamable HTTP media types", async () => {
  const { checkHealth } = await import("../monitor.mjs");
  const previous = new Map();
  for (const name of ["MCP_MONITOR_URL", "MCP_MONITOR_HOST", "MCP_MONITOR_ORIGIN", "MCP_MONITOR_EXPECTED_VERSION", "MCP_HTTP_JWT_SECRET", "MCP_HTTP_JWT_ISSUER", "MCP_HTTP_JWT_AUDIENCE"]) {
    previous.set(name, process.env[name]);
  }
  const originalFetch = globalThis.fetch;
  let requestOptions;
  const requests = [];
  let attempts = 0;
  globalThis.fetch = async (_url, options) => {
    attempts += 1;
    requests.push(options);
    if (attempts === 1) throw new TypeError("fetch failed");
    if (attempts === 3) return new Response("", { status: 200 });
    requestOptions = options;
    return new Response(JSON.stringify({
      result: { protocolVersion: "2025-11-25", serverInfo: { name: "claude-obsidian-mcp", version: "0.1.8" } },
    }), { status: 200, headers: { "Mcp-Session-Id": "health-session" } });
  };
  Object.assign(process.env, {
    MCP_MONITOR_URL: "http://127.0.0.1:3000/mcp",
    MCP_MONITOR_HOST: "127.0.0.1:3000",
    MCP_MONITOR_ORIGIN: "http://127.0.0.1:3000",
    MCP_MONITOR_EXPECTED_VERSION: "0.1.8",
    MCP_HTTP_JWT_SECRET: "0123456789abcdef0123456789abcdef",
    MCP_HTTP_JWT_ISSUER: "https://issuer.example",
    MCP_HTTP_JWT_AUDIENCE: "claude-obsidian",
  });
  try {
    await checkHealth();
    assert.equal(attempts, 3);
    assert.equal(requestOptions.headers.Accept, "application/json, text/event-stream");
    assert.match(requestOptions.headers.Authorization, /^Bearer /);
    assert.match(requestOptions.body, /"method":"initialize"/);
    assert.equal(requestOptions.method, "POST");
    assert.equal(requests[2].method, "DELETE");
    assert.equal(requests[2].headers["Mcp-Session-Id"], "health-session");
  } finally {
    globalThis.fetch = originalFetch;
    for (const [name, value] of previous) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});
