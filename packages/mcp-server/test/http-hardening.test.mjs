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
});
