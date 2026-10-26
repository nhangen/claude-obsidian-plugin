#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, readdir, cp, writeFile, rm, mkdir, stat } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceRuntime = path.join(root, "packages/client/vendor/mcp-remote-read");
const authSecret = "fixture-auth-secret-181";
const sessionSecretPrefix = "fixture-session-secret-181";
const mutation = process.argv[2] ?? "none";
const allowedMutations = new Set(["none", "captured-session", "read-allowlist", "clear-session", "preauthenticated-http", "unresolved-bearer", "unresolved-header", "unresolved-header-nonpreauth", "first-authorization-only", "unresolved-client-info"]);
assert(allowedMutations.has(mutation), `unknown mutation: ${mutation}`);
assert(mutation === "none" || !process.env.OBSIDIAN_MCP_TEST_READ_LAUNCHER, "mutations require the direct vendored runtime");

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function filesBelow(directory, prefix = "") {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relative = path.posix.join(prefix, entry.name);
    if (entry.isDirectory()) result.push(...await filesBelow(path.join(directory, entry.name), relative));
    else result.push(relative);
  }
  return result.sort();
}

async function verifyRuntime() {
  const provenanceBytes = await readFile(path.join(sourceRuntime, "provenance.json"));
  const provenance = JSON.parse(provenanceBytes);
  const expected = [
    ...Object.keys(provenance.files),
    provenance.patch.path,
    "provenance.json",
  ].sort();
  assert.deepEqual(await filesBelow(sourceRuntime), expected, "vendored runtime allowlist drifted");
  for (const [relative, digest] of Object.entries(provenance.files)) {
    assert.equal(sha256(await readFile(path.join(sourceRuntime, relative))), digest, `${relative} hash drifted`);
  }
  for (const [relative, mode] of Object.entries(provenance.fileModes)) {
    const actual = `0${((await stat(path.join(sourceRuntime, relative))).mode & 0o777).toString(8)}`;
    assert.equal(actual, mode, `${relative} mode drifted`);
  }
  assert.equal(provenance.runtime.requiresNpm, false, "read bridge unexpectedly requires npm at runtime");
  assert.deepEqual(provenance.runtime.retryableTools, ["obsidian_find_notes"], "read retry allowlist drifted");
  const patchPath = path.join(sourceRuntime, provenance.patch.path);
  assert.equal(sha256(await readFile(patchPath)), provenance.patch.sha256, "patch hash drifted");
}

async function installRuntime(temp, name = "runtime", headerGate = false) {
  const emptyParent = path.join(temp, `empty-parent-${name}`);
  const runtime = path.join(emptyParent, name);
  await mkdir(emptyParent, { recursive: true });
  await cp(sourceRuntime, runtime, { recursive: true });
  const bundlePath = path.join(runtime, "mcp-remote-read.mjs");
  let bundle = await readFile(bundlePath, "utf8");
  if (mutation === "captured-session") {
    const before = "return error51 instanceof SdkHttpError && error51.status === 404 ? error51[requestSessionIdForError] : void 0;";
    const after = "return error51 instanceof SdkHttpError && error51.status === 404 ? transportToServer.sessionId : void 0;";
    assert(bundle.includes(before));
    bundle = bundle.replace(before, after);
  } else if (mutation === "read-allowlist") {
    const before = 'return message.method === "tools/call" && message.params?.name === "obsidian_find_notes";';
    const after = 'return message.method === "tools/call";';
    assert(bundle.includes(before));
    bundle = bundle.replace(before, after);
  } else if (mutation === "clear-session") {
    const before = "if (currentId !== void 0 && currentId !== expiredId) return;\n    const id = `mcp-remote-reinit-${++reinitSeq}`;";
    const after = "if (currentId !== void 0 && currentId !== expiredId) return;\n    transportToServer._sessionId = void 0;\n    const id = `mcp-remote-reinit-${++reinitSeq}`;";
    assert(bundle.includes(before));
    bundle = bundle.replace(before, after);
  } else if (mutation === "preauthenticated-http") {
    const before = "  if (!preauthenticatedHttp) {";
    const after = "  if (true) {";
    assert(bundle.includes(before));
    bundle = bundle.replace(before, after);
  }
  else if (mutation === "unresolved-bearer") {
    const before = ' || authorization.includes("${")';
    assert(bundle.includes(before));
    bundle = bundle.replace(before, "");
  } else if (mutation === "unresolved-header") {
    const before = '    if (typeof value === "string" && value.includes("${")) {';
    const after = "    if (false) {";
    assert(bundle.includes(before));
    bundle = bundle.replace(before, after);
  } else if (mutation === "unresolved-header-nonpreauth") {
    const before = '    if (typeof value === "string" && value.includes("${")) {';
    const after = '    if (preauthenticatedHttp && typeof value === "string" && value.includes("${")) {';
    assert(bundle.includes(before));
    bundle = bundle.replace(before, after);
  } else if (mutation === "first-authorization-only") {
    const before = "for (const [name, authorization] of authHeaders) {";
    assert(bundle.includes(before));
    bundle = bundle.replace(before, "for (const [name, authorization] of authHeaders.slice(0, 1)) {");
  } else if (mutation === "unresolved-client-info") {
    const before = '  if (expanded.includes("${")) {\n    throw new Error(formatEnvError(context, tracker));\n  }';
    assert(bundle.includes(before));
    bundle = bundle.replace(before, "  if (false) {\n  }");
  }
  if (headerGate) {
    const before = "      const headers = await this._commonHeaders();\n      this._applyBodyDerivedHeaders(headers, message);";
    const after = `      if (process.env.OBSIDIAN_MCP_TEST_HEADER_GATE && message.method === "tools/call" && message.params?.name === "obsidian_find_notes") {
        globalThis.__obsidianHeaderGateCount = (globalThis.__obsidianHeaderGateCount ?? 0) + 1;
        if (globalThis.__obsidianHeaderGateCount === 2) {
          const fs = require("node:fs");
          const marker = process.env.OBSIDIAN_MCP_TEST_HEADER_GATE;
          fs.writeFileSync(\`${"${marker}"}.entered\`, "");
          while (!fs.existsSync(\`${"${marker}"}.release\`)) await new Promise((resolve) => setTimeout(resolve, 5));
        }
      }
      const headers = await this._commonHeaders();
      this._applyBodyDerivedHeaders(headers, message);`;
    assert(bundle.includes(before));
    bundle = bundle.replace(before, after);
  }
  await writeFile(bundlePath, bundle);
  return bundlePath;
}

function jsonResponse(response, status, body, sessionId) {
  const headers = { "content-type": "application/json" };
  if (sessionId) headers["mcp-session-id"] = sessionId;
  response.writeHead(status, headers);
  response.end(JSON.stringify(body));
}

function sessionNotFound(response) {
  jsonResponse(response, 404, { jsonrpc: "2.0", id: null, error: { code: -32001, message: "Session not found" } });
}

function httpError(response, status, message) {
  jsonResponse(response, status, { jsonrpc: "2.0", id: null, error: { code: -32001, message } });
}

function okResult(response, request, sessionId) {
  jsonResponse(response, 200, {
    jsonrpc: "2.0",
    id: request.id,
    result: { content: [{ type: "text", text: JSON.stringify({ query: request.params?.arguments?.query ?? "write" }) }] },
  }, sessionId);
}

class FixtureServer {
  constructor(mode) {
    this.mode = mode;
    this.initializations = 0;
    this.initializedNotifications = 0;
    this.oldRequests = [];
    this.reinitResponse = null;
    this.newSession = null;
    this.firstRetryFinished = false;
    this.toolAttempts = 0;
    this.metadataRequests = 0;
    this.preSessionGets = 0;
    this.streamGets = 0;
    this.streamResponses = new Set();
    this.requestCount = 0;
    this.initializeAuthorization = [];
    this.initializeOrigins = [];
    this.reinitStarted = new Promise((resolve) => { this.resolveReinitStarted = resolve; });
  }

  async start() {
    this.server = http.createServer((request, response) => this.handle(request, response).catch((error) => {
      response.destroy(error);
    }));
    await new Promise((resolve) => this.server.listen(0, "127.0.0.1", resolve));
    this.url = `http://127.0.0.1:${this.server.address().port}/mcp`;
  }

  async stop() {
    for (const response of this.streamResponses) response.end();
    await new Promise((resolve) => this.server.close(resolve));
  }

  async handle(httpRequest, response) {
    this.requestCount++;
    if (httpRequest.method === "GET") {
      if (httpRequest.url !== "/mcp") {
        this.metadataRequests++;
        assert.equal(httpRequest.headers.authorization, void 0, "metadata probe carried authorization");
        assert.equal(httpRequest.headers.origin, void 0, "metadata probe carried origin");
        jsonResponse(response, 403, { error: { code: -32000, message: "forbidden" } });
        return;
      }
      const sessionId = httpRequest.headers["mcp-session-id"];
      if (!sessionId) {
        this.preSessionGets++;
        jsonResponse(response, 400, { jsonrpc: "2.0", id: null, error: { code: -32600, message: "session required" } });
        return;
      }
      assert.equal(httpRequest.headers.authorization, `Bearer ${authSecret}`, "stream GET lost authorization");
      assert.equal(httpRequest.headers.origin, new URL(this.url).origin, "stream GET lost origin");
      this.streamGets++;
      this.streamResponses.add(response);
      response.on("close", () => this.streamResponses.delete(response));
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.write(": connected\n\n");
      return;
    }
    if (httpRequest.method !== "POST") {
      response.writeHead(405, { "content-type": "text/plain" }).end("method not allowed");
      return;
    }
    let raw = "";
    for await (const chunk of httpRequest) raw += chunk;
    const request = raw ? JSON.parse(raw) : {};
    const sessionId = httpRequest.headers["mcp-session-id"];
    if (process.env.OBSIDIAN_MCP_TEST_TRACE === "1") process.stderr.write(`fixture ${request.method ?? "unknown"}\n`);
    if (request.method === "server/discover") {
      jsonResponse(response, 200, { jsonrpc: "2.0", id: request.id, error: { code: -32601, message: "not implemented" } });
      return;
    }
    if (request.method === "initialize") {
      this.initializations++;
      this.initializeAuthorization.push(httpRequest.headers.authorization);
      this.initializeOrigins.push(httpRequest.headers.origin);
      if (this.mode === "invalid-credential") {
        httpError(response, 401, "Unauthorized");
        return;
      }
      const nextSession = `${sessionSecretPrefix}-${this.initializations}`;
      const answer = () => jsonResponse(response, 200, {
        jsonrpc: "2.0",
        id: request.id,
        result: {
          protocolVersion: "2025-11-25",
          capabilities: { tools: {} },
          serverInfo: { name: "fixture", version: "1" },
        },
      }, nextSession);
      if (this.initializations === 1) {
        answer();
      } else if (this.mode === "midcycle-fail") {
        this.newSession = nextSession;
        this.reinitResponse = () => httpError(response, 500, "initialize failed");
        this.resolveReinitStarted();
      } else if (this.mode === "burst") {
        this.newSession = nextSession;
        this.reinitResponse = answer;
        this.releaseBurstIfReady();
      } else if (this.mode === "midcycle" || this.mode === "pre-header") {
        this.newSession = nextSession;
        this.reinitResponse = answer;
        this.resolveReinitStarted();
      } else {
        this.newSession = nextSession;
        if (this.initializations > 1) this.resolveReinitStarted();
        answer();
      }
      return;
    }
    if (request.method === "notifications/initialized") {
      this.initializedNotifications++;
      response.writeHead(202).end();
      return;
    }
    if (request.method !== "tools/call") {
      jsonResponse(response, 200, { jsonrpc: "2.0", id: request.id, error: { code: -32601, message: "unsupported" } }, sessionId);
      return;
    }
    this.toolAttempts++;
    if (sessionId === `${sessionSecretPrefix}-1`) {
      if (this.mode === "write") {
        sessionNotFound(response);
        return;
      }
      if (this.mode === "normal") {
        okResult(response, request, sessionId);
        return;
      }
      if (this.mode === "http-408") {
        httpError(response, 408, "Request timed out");
        return;
      }
      if (this.mode === "auth") {
        httpError(response, 401, "Unauthorized");
        return;
      }
      if (this.mode === "midcycle" || this.mode === "midcycle-fail" || this.mode === "second-404") {
        sessionNotFound(response);
        return;
      }
      this.oldRequests.push({ request, response });
      if (this.mode === "burst" && this.oldRequests.length === 4) {
        sessionNotFound(this.oldRequests[0].response);
        this.releaseBurstIfReady();
      } else if (this.mode === "late" && this.oldRequests.length === 2) {
        sessionNotFound(this.oldRequests[0].response);
      } else if (this.mode === "pre-header" && this.oldRequests.length > 1) {
        sessionNotFound(response);
      }
      return;
    }
    if (sessionId === this.newSession) {
      if (this.mode === "second-404") {
        sessionNotFound(response);
        return;
      }
      okResult(response, request, sessionId);
      if (this.mode === "late" && !this.firstRetryFinished) {
        this.firstRetryFinished = true;
        sessionNotFound(this.oldRequests[1].response);
      }
      return;
    }
    sessionNotFound(response);
  }

  releaseBurstIfReady() {
    if (this.oldRequests.length !== 4 || !this.reinitResponse) return;
    for (const held of this.oldRequests.slice(1)) sessionNotFound(held.response);
    this.reinitResponse();
    this.reinitResponse = null;
  }

  releaseMidcycle() {
    assert(this.reinitResponse, "midcycle reinitialization was not held");
    this.reinitResponse();
    this.reinitResponse = null;
  }

  releaseFirstExpiry() {
    assert.equal(this.oldRequests.length, 1, "pre-header fixture did not hold exactly one old-session request");
    sessionNotFound(this.oldRequests[0].response);
  }
}

class Bridge {
  constructor(child) {
    this.child = child;
    this.pending = new Map();
    this.requestedIds = new Set();
    this.responseCounts = new Map();
    this.stdout = "";
    this.stderr = "";
    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      this.stdout += `${line}\n`;
      const message = JSON.parse(line);
      if (message.id !== void 0 && message.id !== null) {
        this.responseCounts.set(message.id, (this.responseCounts.get(message.id) ?? 0) + 1);
      }
      const settle = this.pending.get(message.id);
      if (settle) {
        this.pending.delete(message.id);
        settle.resolve(message);
      }
    });
    child.stderr.on("data", (chunk) => { this.stderr += chunk; });
    child.on("exit", (code, signal) => {
      for (const [id, settle] of this.pending) {
        settle.reject(new Error(`bridge exited before ${id}: code=${code} signal=${signal}; stderr=${this.stderr}`));
      }
      this.pending.clear();
    });
  }

  send(message) {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(message, timeoutMs = 15000) {
    assert(!this.requestedIds.has(message.id), `duplicate client request id: ${message.id}`);
    this.requestedIds.add(message.id);
    const answer = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(message.id);
        reject(new Error(`timed out waiting for ${message.id}; stderr=${this.stderr}`));
      }, timeoutMs);
      this.pending.set(message.id, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
    });
    this.send(message);
    return answer;
  }

  async close() {
    this.child.stdin.end();
    const exited = new Promise((resolve) => this.child.once("exit", resolve));
    const wait = (milliseconds) => Promise.race([
      exited.then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), milliseconds)),
    ]);
    if (!await wait(1000)) this.child.kill("SIGTERM");
    if (!await wait(1000)) this.child.kill("SIGKILL");
    assert(await wait(1000), "bridge did not exit after SIGKILL");
    for (const id of this.requestedIds) {
      assert.equal(this.responseCounts.get(id), 1, `client request ${id} received ${this.responseCounts.get(id) ?? 0} responses`);
    }
  }
}

async function startBridge(runtime, url, childRoot, extraEnv = {}, credential = authSecret, expectInitializeError = false) {
  const configuredLauncher = process.env.OBSIDIAN_MCP_TEST_READ_LAUNCHER;
  if (configuredLauncher) assert(path.isAbsolute(configuredLauncher), "OBSIDIAN_MCP_TEST_READ_LAUNCHER must be absolute");
  const home = path.join(childRoot, "home");
  const xdgConfig = path.join(childRoot, "xdg-config");
  const xdgCache = path.join(childRoot, "xdg-cache");
  const xdgData = path.join(childRoot, "xdg-data");
  const mcpRemoteConfig = path.join(childRoot, "mcp-remote-config");
  await Promise.all([home, xdgConfig, xdgCache, xdgData, mcpRemoteConfig].map((directory) => mkdir(directory, { recursive: true })));
  const env = {
    ...process.env,
    HOME: home,
    XDG_CONFIG_HOME: xdgConfig,
    XDG_CACHE_HOME: xdgCache,
    XDG_DATA_HOME: xdgData,
    MCP_REMOTE_CONFIG_DIR: mcpRemoteConfig,
    OBSIDIAN_MCP_TEST_ORIGIN: new URL(url).origin,
    ...extraEnv,
  };
  for (const name of ["NODE_OPTIONS", "NODE_PATH", "DEBUG", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]) {
    delete env[name];
  }
  const child = spawn(
    configuredLauncher ?? process.execPath,
    configuredLauncher ? [] : [runtime, url, "--allow-http", "--preauthenticated-http", "--header", `Authorization:Bearer ${credential}`, "--header", "Origin:${OBSIDIAN_MCP_TEST_ORIGIN}", "--silent"],
    {
      env: configuredLauncher ? {
        ...env,
        OBSIDIAN_MCP_ALLOW_HTTP: "1",
        OBSIDIAN_MCP_READ_ENDPOINT: url,
        OBSIDIAN_MCP_READ_ORIGIN: new URL(url).origin,
        OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER: "env",
        OBSIDIAN_MCP_READ_TOKEN_ENV: "OBSIDIAN_MCP_TEST_TOKEN",
        OBSIDIAN_MCP_TEST_TOKEN: credential,
      } : env,
      cwd: configuredLauncher ? os.tmpdir() : path.dirname(path.dirname(runtime)),
      stdio: ["pipe", "pipe", "pipe"],
    },
  );
  const bridge = new Bridge(child);
  const initialized = await bridge.request({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "fixture", version: "1" } },
  });
  if (expectInitializeError) {
    assert(initialized.error && !initialized.result, `rejected credential initialized: ${JSON.stringify(initialized)}`);
    return bridge;
  }
  assert.equal(initialized.result?.protocolVersion, "2025-11-25", bridge.stderr);
  bridge.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  await new Promise((resolve) => setTimeout(resolve, 20));
  return bridge;
}

async function rejectedStartup(runtime, args, temp, stderrPattern, { preauthenticated = true, seedRegistrationHeaders = null, extraEnv = {} } = {}) {
  const server = new FixtureServer("normal");
  await server.start();
  const childRoot = await mkdtemp(path.join(temp, "child-rejected-startup."));
  let seededRegistration = null;
  if (seedRegistrationHeaders) {
    const hash = createHash("md5").update(`${server.url}|${JSON.stringify(seedRegistrationHeaders)}`).digest("hex");
    const storeDir = path.join(childRoot, "mcp-remote-v1");
    await mkdir(storeDir, { recursive: true });
    seededRegistration = path.join(storeDir, `${hash}_client_info.json`);
    await writeFile(seededRegistration, JSON.stringify({ client_id: "fixture-client", redirect_uris: ["http://localhost:1/stale-callback"] }));
  }
  const flags = [
    "--allow-http",
    ...(preauthenticated ? ["--preauthenticated-http"] : []),
    ...args,
    ...(stderrPattern ? [] : ["--silent"]),
  ];
  const child = spawn(process.execPath, [runtime, server.url, ...flags], {
    env: { ...process.env, ...extraEnv, HOME: childRoot, XDG_CONFIG_HOME: childRoot, MCP_REMOTE_CONFIG_DIR: childRoot },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const exited = new Promise((resolve) => child.once("exit", resolve));
  let timeout;
  try {
    const code = await Promise.race([
      exited,
      new Promise((resolve) => { timeout = setTimeout(() => resolve(null), 3000); }),
    ]);
    if (code === null) {
      child.kill("SIGKILL");
      await exited;
      assert.fail(`invalid ${preauthenticated ? "preauthenticated" : "non-preauthenticated"} startup did not exit`);
    }
    assert.notEqual(code, 0, `invalid ${preauthenticated ? "preauthenticated" : "non-preauthenticated"} startup succeeded: ${stderr}`);
    assert.equal(server.requestCount, 0, `invalid ${preauthenticated ? "preauthenticated" : "non-preauthenticated"} startup reached the network`);
    if (stderrPattern) assert.match(stderr, stderrPattern, "invalid startup failed for the wrong reason");
    if (seededRegistration) await access(seededRegistration).catch(() => assert.fail("rejected startup deleted the cached client registration"));
  } finally {
    clearTimeout(timeout);
    if (child.exitCode === null) child.kill("SIGKILL");
    await server.stop();
  }
}

async function resolvedClientInfoStartup(runtime, args, temp, extraEnv = {}) {
  const server = new FixtureServer("normal");
  await server.start();
  const childRoot = await mkdtemp(path.join(temp, "child-resolved-startup."));
  const flags = [
    "--allow-http",
    ...args,
  ];
  const child = spawn(process.execPath, [runtime, server.url, ...flags], {
    env: { ...process.env, ...extraEnv, HOME: childRoot, XDG_CONFIG_HOME: childRoot, MCP_REMOTE_CONFIG_DIR: childRoot },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const exited = new Promise((resolve) => child.once("exit", resolve));
  try {
    const deadline = Date.now() + 5000;
    while (server.requestCount === 0 && child.exitCode === null && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    assert.doesNotMatch(stderr, /static OAuth client information has an unresolved \$\{\.\.\.\} placeholder/);
    assert(server.requestCount > 0, `resolved client info startup did not reach the server: ${stderr}`);
    assert.match(stderr, /Replacing \$\{RESOLVED_CLIENT_ID\} with environment value in/, "resolved placeholder was not expanded");
  } finally {
    if (child.exitCode === null) child.kill("SIGKILL");
    await exited.catch(() => {});
    await server.stop();
  }
}

async function invalidCredentialScenario(runtime, temp) {
  const server = new FixtureServer("invalid-credential");
  await server.start();
  const childRoot = await mkdtemp(path.join(temp, "child-invalid-credential."));
  const bridge = await startBridge(runtime, server.url, childRoot, {}, "rejected-credential", true);
  try {
    assert.equal(server.metadataRequests, 0, "rejected credential triggered metadata discovery");
    assert.equal(server.preSessionGets, 0, "rejected credential triggered a sessionless GET");
    assert.equal(server.initializations, 1, "rejected credential retried initialization");
    assert.equal(server.streamGets, 0, "rejected credential opened a stream");
    assert.deepEqual(server.initializeAuthorization, ["Bearer rejected-credential"], "initialize did not forward the rejected credential");
    assert.deepEqual(server.initializeOrigins, [new URL(server.url).origin], "initialize did not forward Origin");
    await assertNoSecrets(bridge, childRoot, ["rejected-credential"]);
  } finally {
    await bridge.close();
    await server.stop();
  }
}

async function assertNoSecrets(bridge, childRoot, secrets = [authSecret, sessionSecretPrefix]) {
  for (const secret of secrets) {
    assert(!bridge.stdout.includes(secret), `bridge stdout exposed ${secret}`);
    assert(!bridge.stderr.includes(secret), `bridge stderr exposed ${secret}`);
  }
  for (const relative of await filesBelow(childRoot)) {
    const body = await readFile(path.join(childRoot, relative));
    for (const secret of secrets) assert(!body.includes(secret), `${relative} exposed ${secret}`);
  }
}

function readRequest(id) {
  return { jsonrpc: "2.0", id, method: "tools/call", params: { name: "obsidian_find_notes", arguments: { query: `query-${id}` } } };
}

async function waitFor(check, message, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(message);
}

async function scenario(runtime, mode, temp) {
  const server = new FixtureServer(mode);
  await server.start();
  const childRoot = await mkdtemp(path.join(temp, `child-${mode}.`));
  const headerGate = path.join(childRoot, "header-gate");
  const bridge = await startBridge(runtime, server.url, childRoot, mode === "pre-header" ? { OBSIDIAN_MCP_TEST_HEADER_GATE: headerGate } : {});
  try {
    if (mode === "normal") {
      const serial = await bridge.request(readRequest(2));
      assert(serial.result && !serial.error, `ordinary serial read failed: ${JSON.stringify(serial)}`);
      const answers = await Promise.all([3, 4, 5, 6].map((id) => bridge.request(readRequest(id))));
      assert(answers.every((answer) => answer.result && !answer.error), `ordinary burst failed: ${JSON.stringify(answers)}`);
      assert.equal(server.metadataRequests, 0, "preauthenticated startup probed OAuth metadata");
      assert.equal(server.preSessionGets, 0, "preauthenticated startup sent a sessionless GET");
      assert.equal(server.initializations, 1, "preauthenticated startup initialized more than once");
      assert.equal(server.initializedNotifications, 1, "preauthenticated startup sent an unexpected number of initialized notifications");
      assert.equal(server.streamGets, 1, "preauthenticated startup opened an unexpected number of streams");
      assert.equal(server.toolAttempts, 5, "ordinary reads were replayed");
    } else if (mode === "burst") {
      const answers = await Promise.all([2, 3, 4, 5].map((id) => bridge.request(readRequest(id))));
      assert(answers.every((answer) => answer.result && !answer.error), `burst did not recover: ${JSON.stringify(answers)}`);
      assert.equal(server.initializations, 2, "burst recovery did not share one reinitialization");
    } else if (mode === "late") {
      const answers = await Promise.all([6, 7].map((id) => bridge.request(readRequest(id))));
      assert(answers.every((answer) => answer.result && !answer.error), `late 404 did not reuse current session: ${JSON.stringify(answers)}`);
      assert.equal(server.initializations, 2, "late old-session 404 triggered an extra reinitialization");
    } else if (mode === "midcycle") {
      const first = bridge.request(readRequest(8));
      await Promise.race([
        server.reinitStarted,
        new Promise((_, reject) => setTimeout(() => reject(new Error("midcycle reinitialization did not start")), 3000)),
      ]);
      const second = bridge.request(readRequest(9));
      await new Promise((resolve) => setTimeout(resolve, 50));
      assert.equal(server.toolAttempts, 1, "read entering during recovery was sent without a session");
      server.releaseMidcycle();
      const answers = await Promise.all([first, second]);
      assert(answers.every((answer) => answer.result && !answer.error), `midcycle read failed: ${JSON.stringify(answers)}`);
      assert.equal(server.initializations, 2, "midcycle read triggered another reinitialization");
      assert.equal(server.toolAttempts, 3, "midcycle read was replayed unexpectedly");
    } else if (mode === "midcycle-fail") {
      const first = bridge.request(readRequest(10));
      await Promise.race([
        server.reinitStarted,
        new Promise((_, reject) => setTimeout(() => reject(new Error("failed reinitialization did not start")), 3000)),
      ]);
      const second = bridge.request(readRequest(11));
      await new Promise((resolve) => setTimeout(resolve, 50));
      assert.equal(server.toolAttempts, 1, "read entering failed recovery reached the server");
      server.releaseMidcycle();
      const answers = await Promise.all([first, second]);
      assert(answers.every((answer) => answer.error && !answer.result), `failed reinitialization returned success: ${JSON.stringify(answers)}`);
      assert.equal(server.initializations, 2, "failed reinitialization looped");
      assert.equal(server.toolAttempts, 1, "failed reinitialization sent an unsent read");
    } else if (mode === "pre-header") {
      const first = bridge.request(readRequest(12));
      await waitFor(() => server.oldRequests.length === 1, "first pre-header request did not reach the old session");
      const second = bridge.request(readRequest(13));
      await waitFor(async () => {
        try {
          await access(`${headerGate}.entered`);
          return true;
        } catch {
          return false;
        }
      }, "second pre-header request did not enter the header await");
      server.releaseFirstExpiry();
      await Promise.race([
        server.reinitStarted,
        new Promise((_, reject) => setTimeout(() => reject(new Error("pre-header reinitialization did not start")), 3000)),
      ]);
      assert.equal(server.toolAttempts, 1, "pre-header request reached the server before its await was released");
      await writeFile(`${headerGate}.release`, "");
      await waitFor(() => server.toolAttempts === 2, "pre-header request did not preserve its old wire session");
      server.releaseMidcycle();
      const answers = await Promise.all([first, second]);
      assert(answers.every((answer) => answer.result && !answer.error), `pre-header recovery failed: ${JSON.stringify(answers)}`);
      assert.equal(server.initializations, 2, "pre-header recovery did not share one reinitialization");
      assert.equal(server.toolAttempts, 4, "pre-header recovery sent an unexpected number of tool attempts");
    } else if (mode === "second-404") {
      const answer = await bridge.request(readRequest(11));
      assert(answer.error && !answer.result, `second 404 returned success: ${JSON.stringify(answer)}`);
      assert.equal(server.initializations, 2, "second 404 triggered another reinitialization");
      assert.equal(server.toolAttempts, 2, "second 404 exceeded one replay");
    } else if (mode === "http-408" || mode === "auth") {
      const answer = await bridge.request(readRequest(12), 5000);
      assert(answer.error && !answer.result, `${mode} returned success: ${JSON.stringify(answer)}`);
      assert.equal(server.initializations, 1, `${mode} triggered reinitialization`);
      assert.equal(server.toolAttempts, 1, `${mode} replayed the read`);
    } else {
      const answer = await bridge.request({
        jsonrpc: "2.0",
        id: 8,
        method: "tools/call",
        params: { name: "obsidian_keeper_save", arguments: { title: "must-not-replay" } },
      });
      assert(answer.error && !answer.result, `nonallowlisted write was replayed: ${JSON.stringify(answer)}`);
      assert.equal(server.initializations, 1, "nonallowlisted write triggered reinitialization");
    }
  } finally {
    await bridge.close();
    await assertNoSecrets(bridge, childRoot);
    await server.stop();
  }
}

const temp = await mkdtemp(path.join(os.tmpdir(), "obsidian-mcp-read-bridge."));
try {
  await verifyRuntime();
  const packedRuntime = Boolean(process.env.OBSIDIAN_MCP_TEST_READ_LAUNCHER);
  const runtime = packedRuntime ? null : await installRuntime(temp);
  if (!packedRuntime) {
    await rejectedStartup(runtime, [], temp);
    await rejectedStartup(runtime, ["--preauthenticated-http=false", "--header", `Authorization:Bearer ${authSecret}`], temp);
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--transport", "sse-only"], temp);
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--device-code"], temp);
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer ${UNSET}"], temp, /--preauthenticated-http Authorization header has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m);
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer abc${UNSET}def"], temp, /--preauthenticated-http Authorization header has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m);
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${UNSET}"], temp, /header 'X-Foo' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m);
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:abc${UNSET}def"], temp, /header 'X-Foo' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m);
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${UNSET}"], temp, /header 'X-Foo' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m, { preauthenticated: false });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "authorization:Bearer ${UNSET}"], temp, /--preauthenticated-http Authorization header has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m);
    await rejectedStartup(runtime, ["--header", "authorization:Bearer ${UNSET}", "--header", `Authorization:Bearer ${authSecret}`], temp, /--preauthenticated-http Authorization header has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m);
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer ${UNSET}"], temp, /header 'Authorization' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m, { preauthenticated: false });
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer ${UNSET}"], temp, /header 'Authorization' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m, { preauthenticated: false, seedRegistrationHeaders: { Authorization: "Bearer ${UNSET}" } });
    const clientInfoUnresolvedFile = path.join(temp, "client-info-unresolved.json");
    await writeFile(clientInfoUnresolvedFile, JSON.stringify({ client_id: "${UNSET_CLIENT_ID}", client_secret: "secret" }));
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "${UNSET}"}'], temp, /static OAuth client information has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m, { preauthenticated: false });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "client", "client_secret": "sec_${UNSET}_ret"}'], temp, /static OAuth client information has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m, { preauthenticated: false });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "${RESOLVED_CLIENT_ID}", "client_secret": "${UNSET}"}'], temp, /static OAuth client information has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m, { preauthenticated: false, extraEnv: { RESOLVED_CLIENT_ID: "client-resolved-partial" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", `@${clientInfoUnresolvedFile}`], temp, /static OAuth client information has an unresolved \$\{\.\.\.\} placeholder for 'UNSET_CLIENT_ID'$/m, { preauthenticated: false });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "${UNSET}"}'], temp, /static OAuth client information has an unresolved \$\{\.\.\.\} placeholder for 'UNSET'$/m, { preauthenticated: false, seedRegistrationHeaders: { Authorization: `Bearer ${authSecret}` } });
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer ${OFFENDING_BEARER}"], temp, /--preauthenticated-http Authorization header environment variable 'OFFENDING_BEARER' contains '\${'$/m, { extraEnv: { OFFENDING_BEARER: "tok${en" } });
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer abc${OFFENDING_BEARER}def"], temp, /--preauthenticated-http Authorization header environment variable 'OFFENDING_BEARER' contains '\${'$/m, { extraEnv: { OFFENDING_BEARER: "tok${en" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${OFFENDING_HEADER}"], temp, /header 'X-Foo' environment variable 'OFFENDING_HEADER' contains '\${'$/m, { extraEnv: { OFFENDING_HEADER: "val${ue" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:abc${OFFENDING_HEADER}def"], temp, /header 'X-Foo' environment variable 'OFFENDING_HEADER' contains '\${'$/m, { extraEnv: { OFFENDING_HEADER: "val${ue" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${OFFENDING_HEADER}"], temp, /header 'X-Foo' environment variable 'OFFENDING_HEADER' contains '\${'$/m, { preauthenticated: false, extraEnv: { OFFENDING_HEADER: "val${ue" } });
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer ${OFFENDING_AUTH}"], temp, /header 'Authorization' environment variable 'OFFENDING_AUTH' contains '\${'$/m, { preauthenticated: false, extraEnv: { OFFENDING_AUTH: "tok${en" } });
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer ${OFFENDING_AUTH}"], temp, /header 'Authorization' environment variable 'OFFENDING_AUTH' contains '\${'$/m, { preauthenticated: false, seedRegistrationHeaders: { Authorization: "Bearer ${OFFENDING_AUTH}" }, extraEnv: { OFFENDING_AUTH: "tok${en" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "${OFFENDING}"}'], temp, /static OAuth client information environment variable 'OFFENDING' contains '\${'$/m, { preauthenticated: false, extraEnv: { OFFENDING: "client${bad" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "client", "client_secret": "sec_${OFFENDING}_ret"}'], temp, /static OAuth client information environment variable 'OFFENDING' contains '\${'$/m, { preauthenticated: false, extraEnv: { OFFENDING: "client${bad" } });
    const clientInfoOffendingFile = path.join(temp, "client-info-offending.json");
    await writeFile(clientInfoOffendingFile, JSON.stringify({ client_id: "${OFFENDING_FILE}", client_secret: "secret" }));
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", `@${clientInfoOffendingFile}`], temp, /static OAuth client information environment variable 'OFFENDING_FILE' contains '\${'$/m, { preauthenticated: false, extraEnv: { OFFENDING_FILE: "file${bad" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:abc${def"], temp, /header 'X-Foo' has an unresolved \$\{\.\.\.\} placeholder$/m);
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "${}"}'], temp, /static OAuth client information has an unresolved \$\{\.\.\.\} placeholder$/m, { preauthenticated: false });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${UNSET_A}-${UNSET_B}-${UNSET_A}"], temp, /header 'X-Foo' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET_A', 'UNSET_B'$/m);
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${OFFENDING_A}-${OFFENDING_B}"], temp, /header 'X-Foo' environment variables 'OFFENDING_A', 'OFFENDING_B' contain '\${'$/m, { extraEnv: { OFFENDING_A: "a${1", OFFENDING_B: "b${2" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "${UNSET_A}", "client_secret": "${OFFENDING}"}'], temp, /static OAuth client information has an unresolved \$\{\.\.\.\} placeholder for 'UNSET_A' and environment variable 'OFFENDING' contains '\${'$/m, { preauthenticated: false, extraEnv: { OFFENDING: "sec${ret" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${UNSET_A}-${OFFENDING}"], temp, /header 'X-Foo' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET_A' and environment variable 'OFFENDING' contains '\${'$/m, { extraEnv: { OFFENDING: "val${ue" } });
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer ${UNSET_A}-${OFFENDING}"], temp, /--preauthenticated-http Authorization header has an unresolved \$\{\.\.\.\} placeholder for 'UNSET_A' and environment variable 'OFFENDING' contains '\${'$/m, { extraEnv: { OFFENDING: "tok${en" } });
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer ${OFFENDING}-abc${def"], temp, /--preauthenticated-http Authorization header environment variable 'OFFENDING' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { extraEnv: { OFFENDING: "tok${en" } });
    await rejectedStartup(runtime, ["--header", "Authorization:Bearer abc${} ${OFFENDING}"], temp, /--preauthenticated-http Authorization header environment variable 'OFFENDING' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { extraEnv: { OFFENDING: "tok${en" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${OFFENDING}-abc${def"], temp, /header 'X-Foo' environment variable 'OFFENDING' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { extraEnv: { OFFENDING: "val${ue" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:abc${} ${OFFENDING}"], temp, /header 'X-Foo' environment variable 'OFFENDING' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { extraEnv: { OFFENDING: "val${ue" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${OFFENDING}-abc${def"], temp, /header 'X-Foo' environment variable 'OFFENDING' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { preauthenticated: false, extraEnv: { OFFENDING: "val${ue" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${OFFENDING_A}-${OFFENDING_B}-abc${def"], temp, /header 'X-Foo' environment variables 'OFFENDING_A', 'OFFENDING_B' contain '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { extraEnv: { OFFENDING_A: "a${1", OFFENDING_B: "b${2" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${UNSET_A}-${OFFENDING}-abc${def"], temp, /header 'X-Foo' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET_A' and environment variable 'OFFENDING' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { extraEnv: { OFFENDING: "val${ue" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${UNSET_A} abc${def"], temp, /header 'X-Foo' has an unresolved \$\{\.\.\.\} placeholder for 'UNSET_A'; it also has an unresolved \$\{\.\.\.\} placeholder$/m);
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--header", "X-Foo:${OFFENDING}x${"], temp, /header 'X-Foo' environment variable 'OFFENDING' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { extraEnv: { OFFENDING: "${" } });
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "${OFFENDING}", "client_secret": "${}"}'], temp, /static OAuth client information environment variable 'OFFENDING' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { preauthenticated: false, extraEnv: { OFFENDING: "client${bad" } });
    const clientInfoMixedFile = path.join(temp, "client-info-mixed.json");
    await writeFile(clientInfoMixedFile, JSON.stringify({ client_id: "${OFFENDING_FILE}", client_secret: "${}" }));
    await rejectedStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", `@${clientInfoMixedFile}`], temp, /static OAuth client information environment variable 'OFFENDING_FILE' contains '\${'; it also has an unresolved \$\{\.\.\.\} placeholder$/m, { preauthenticated: false, extraEnv: { OFFENDING_FILE: "file${bad" } });
    const clientInfoResolvedFile = path.join(temp, "client-info-resolved.json");
    await writeFile(clientInfoResolvedFile, JSON.stringify({ client_id: "${RESOLVED_CLIENT_ID}", client_secret: "secret" }));
    await resolvedClientInfoStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", '{"client_id": "${RESOLVED_CLIENT_ID}"}'], temp, { RESOLVED_CLIENT_ID: "client-resolved-inline" });
    await resolvedClientInfoStartup(runtime, ["--header", `Authorization:Bearer ${authSecret}`, "--static-oauth-client-info", `@${clientInfoResolvedFile}`], temp, { RESOLVED_CLIENT_ID: "client-resolved-file" });
  }
  await scenario(runtime, "normal", temp);
  await invalidCredentialScenario(runtime, temp);
  await scenario(runtime, "burst", temp);
  await scenario(runtime, "late", temp);
  await scenario(runtime, "midcycle", temp);
  await scenario(runtime, "midcycle-fail", temp);
  if (!packedRuntime) {
    const headerRuntime = await installRuntime(temp, "header-runtime", true);
    await scenario(headerRuntime, "pre-header", temp);
  }
  await scenario(runtime, "second-404", temp);
  await scenario(runtime, "http-408", temp);
  await scenario(runtime, "auth", temp);
  await scenario(runtime, "write", temp);
  console.log(`obsidian-mcp-read-bridge: PASS mutation=${mutation}`);
} finally {
  await rm(temp, { recursive: true, force: true });
}
