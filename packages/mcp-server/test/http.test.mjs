import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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

function token({ scope = "vault:read repo:read", exp = Math.floor(Date.now() / 1000) + 300, aud = audience, iss = issuer } = {}) {
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({ aud, exp, iss, scope }));
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
  assert.doesNotMatch(server.stderr(), new RegExp(secret));
});
