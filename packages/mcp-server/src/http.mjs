import { createHash, createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { createServer as createHttpServer } from "node:http";
import { WebStandardStreamableHTTPServerTransport, validateHostHeader } from "@modelcontextprotocol/server";
import { closeActiveChildren, createServer } from "./stdio.mjs";

const protocolVersions = ["2026-07-28", "2025-11-25"];
const sessions = new Map();
const activeRequests = new Set();

class HttpBoundaryError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function integerSetting(name, fallback, minimum, maximum) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name} must be an integer`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} is outside its allowed range`);
  }
  return value;
}

function listSetting(name, fallback) {
  const values = (process.env[name] ?? fallback).split(",").map((value) => value.trim()).filter(Boolean);
  if (values.length === 0) throw new Error(`${name} must not be empty`);
  return values;
}

function requiredSetting(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function loadHttpConfiguration() {
  const bind = process.env.MCP_HTTP_BIND?.trim() || "127.0.0.1";
  const port = integerSetting("MCP_HTTP_PORT", 3000, 0, 65_535);
  const allowedHosts = listSetting("MCP_HTTP_ALLOWED_HOSTS", "127.0.0.1,localhost");
  const defaultOrigins = `http://127.0.0.1:${port},http://localhost:${port}`;
  const allowedOrigins = listSetting("MCP_HTTP_ALLOWED_ORIGINS", defaultOrigins).map((value) => {
    const parsed = new URL(value);
    if (parsed.origin !== value || !["http:", "https:"].includes(parsed.protocol)) {
      throw new Error("MCP_HTTP_ALLOWED_ORIGINS must contain exact HTTP origins");
    }
    return parsed.origin;
  });
  const jwtSecret = requiredSetting("MCP_HTTP_JWT_SECRET");
  if (Buffer.byteLength(jwtSecret, "utf8") < 32) throw new Error("MCP_HTTP_JWT_SECRET must be at least 32 bytes");
  return {
    bind,
    port,
    allowedHosts,
    allowedOrigins,
    jwtSecret,
    jwtIssuer: requiredSetting("MCP_HTTP_JWT_ISSUER"),
    jwtAudience: requiredSetting("MCP_HTTP_JWT_AUDIENCE"),
    maxBodyBytes: integerSetting("MCP_HTTP_MAX_BODY_BYTES", 1024 * 1024, 1, 64 * 1024 * 1024),
    maxResponseBytes: integerSetting("MCP_HTTP_MAX_RESPONSE_BYTES", 1024 * 1024, 1024, 64 * 1024 * 1024),
    concurrencyLimit: integerSetting("MCP_HTTP_CONCURRENCY_LIMIT", 16, 1, 1024),
    requestTimeoutMs: integerSetting("MCP_HTTP_REQUEST_TIMEOUT_MS", 10_000, 100, 300_000),
  };
}

function jsonResponse(status, code, message, headers = {}) {
  const body = JSON.stringify({ jsonrpc: "2.0", error: { code, message }, id: null });
  return new Response(body, {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

function validateTransportBoundary(req, configuration) {
  const host = validateHostHeader(req.headers.host, configuration.allowedHosts);
  if (!host.ok) throw new HttpBoundaryError(403, -32000, "Forbidden");
  const origin = req.headers.origin;
  if (typeof origin !== "string" || !configuration.allowedOrigins.includes(origin)) {
    throw new HttpBoundaryError(403, -32000, "Forbidden");
  }
  const requestUrl = new URL(req.url ?? "/", `http://${req.headers.host}`);
  if (requestUrl.search) throw new HttpBoundaryError(400, -32600, "Query strings are not allowed");
  if (requestUrl.pathname !== "/mcp") throw new HttpBoundaryError(404, -32601, "Not found");
  return requestUrl;
}

function decodeJwtSegment(segment) {
  if (!/^[A-Za-z0-9_-]+$/.test(segment)) throw new Error("invalid token");
  const bytes = Buffer.from(segment, "base64url");
  if (bytes.toString("base64url") !== segment) throw new Error("invalid token");
  return JSON.parse(bytes.toString("utf8"));
}

function validateToken(req, configuration) {
  const authorization = req.headers.authorization;
  if (typeof authorization !== "string" || !authorization.startsWith("Bearer ")) {
    throw new HttpBoundaryError(401, -32001, "Unauthorized");
  }
  const token = authorization.slice("Bearer ".length);
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some((part) => part.length === 0)) {
    throw new HttpBoundaryError(401, -32001, "Unauthorized");
  }
  try {
    const header = decodeJwtSegment(parts[0]);
    const claims = decodeJwtSegment(parts[1]);
    if (header?.alg !== "HS256" || (header.typ !== undefined && header.typ !== "JWT")) throw new Error("invalid token");
    const expected = createHmac("sha256", configuration.jwtSecret).update(`${parts[0]}.${parts[1]}`).digest();
    const actual = Buffer.from(parts[2], "base64url");
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) throw new Error("invalid token");
    const now = Math.floor(Date.now() / 1000);
    if (claims?.iss !== configuration.jwtIssuer || claims?.aud !== configuration.jwtAudience) throw new Error("invalid token");
    if (!Number.isSafeInteger(claims?.exp) || claims.exp <= now) throw new Error("invalid token");
    if (claims.nbf !== undefined && (!Number.isSafeInteger(claims.nbf) || claims.nbf > now)) throw new Error("invalid token");
    const scopes = Array.isArray(claims.scope)
      ? claims.scope.filter((scope) => typeof scope === "string")
      : typeof claims.scope === "string" ? claims.scope.split(/\s+/).filter(Boolean) : [];
    if (!scopes.includes("vault:read") && !scopes.includes("repo:read")) {
      throw new HttpBoundaryError(403, -32003, "Insufficient scope");
    }
    return {
      fingerprint: createHash("sha256").update(token).digest("base64url"),
      scopes: new Set(scopes),
    };
  } catch (error) {
    if (error instanceof HttpBoundaryError) throw error;
    throw new HttpBoundaryError(401, -32001, "Unauthorized");
  }
}

function readRequestBody(req, maximumBytes, signal) {
  const contentLength = req.headers["content-length"];
  if (typeof contentLength === "string" && /^\d+$/.test(contentLength) && Number(contentLength) > maximumBytes) {
    req.resume();
    throw new HttpBoundaryError(413, -32004, "Request body too large");
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    const cleanup = () => {
      req.off("data", onData);
      req.off("end", onEnd);
      req.off("error", onError);
      req.off("aborted", onAborted);
      signal?.removeEventListener("abort", onAbort);
    };
    const fail = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    };
    const onData = (chunk) => {
      size += chunk.length;
      if (size > maximumBytes) {
        req.resume();
        fail(new HttpBoundaryError(413, -32004, "Request body too large"));
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(Buffer.concat(chunks, size));
    };
    const onError = () => fail(new HttpBoundaryError(400, -32700, "Request body could not be read"));
    const onAborted = () => fail(new HttpBoundaryError(400, -32700, "Request cancelled"));
    const onAbort = () => {
      req.resume();
      fail(new HttpBoundaryError(408, -32008, "Request timed out"));
    };
    req.on("data", onData);
    req.on("end", onEnd);
    req.on("error", onError);
    req.on("aborted", onAborted);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function parseJsonBody(body) {
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    throw new HttpBoundaryError(400, -32700, "Parse error: Invalid JSON");
  }
}

function requiredScopes(message) {
  const messages = Array.isArray(message) ? message : [message];
  const scopes = new Set();
  for (const item of messages) {
    if (!item || typeof item !== "object") continue;
    if (item.method === "tools/call" && item.params?.name === "obsidian_find_notes") scopes.add("vault:read");
    if (item.method === "tools/call" && item.params?.name === "obsidian_commit_meta") scopes.add("repo:read");
    if (typeof item.method === "string" && item.method.startsWith("resources/")) scopes.add("vault:read");
  }
  return scopes;
}

function enforceMessageScopes(message, auth) {
  for (const scope of requiredScopes(message)) {
    if (!auth.scopes.has(scope)) throw new HttpBoundaryError(403, -32003, "Insufficient scope");
  }
}

function nodeHeaders(req) {
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (Array.isArray(value)) headers.set(name, value.join(", "));
    else if (value !== undefined) headers.set(name, value);
  }
  return headers;
}

function webRequest(req, requestUrl, body, signal) {
  return new Request(requestUrl, {
    method: req.method,
    headers: nodeHeaders(req),
    body: body.length > 0 ? body : undefined,
    signal,
  });
}

function createSession() {
  let session;
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: randomUUID,
    enableJsonResponse: true,
    supportedProtocolVersions: protocolVersions,
    onsessioninitialized: (sessionId) => {
      session.id = sessionId;
      sessions.set(sessionId, session);
    },
    onsessionclosed: (sessionId) => {
      sessions.delete(sessionId);
    },
  });
  session = { id: undefined, fingerprint: undefined, server: createServer(), transport };
  return session;
}

async function closeSession(session) {
  if (session.id) sessions.delete(session.id);
  await session.transport.close().catch(() => {});
  await session.server.close().catch(() => {});
}

async function transportResponse(session, request, parsedBody, timeoutMs, controller) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new HttpBoundaryError(408, -32008, "Request timed out"));
    }, timeoutMs);
  });
  try {
    return await Promise.race([session.transport.handleRequest(request, { parsedBody }), timeout]);
  } finally {
    clearTimeout(timer);
  }
}

async function collectResponseBody(response, maximumBytes) {
  if (!response.body) return Buffer.alloc(0);
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximumBytes) throw new HttpBoundaryError(500, -32603, "Response body too large");
      chunks.push(Buffer.from(value));
    }
    return Buffer.concat(chunks, size);
  } finally {
    if (size > maximumBytes) await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

function copyResponseHeaders(response, res) {
  for (const [name, value] of response.headers) res.setHeader(name, value);
}

async function sendWebResponse(response, res, maximumBytes) {
  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.includes("text/event-stream")) {
    const body = await collectResponseBody(response, maximumBytes);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(body);
    return;
  }
  res.statusCode = response.status;
  copyResponseHeaders(response, res);
  res.flushHeaders();
  if (!response.body) {
    res.end();
    return;
  }
  const reader = response.body.getReader();
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximumBytes) break;
      if (!res.write(Buffer.from(value))) await new Promise((resolve) => res.once("drain", resolve));
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
    res.end();
  }
}

function sendBoundaryError(error, res) {
  const response = error instanceof HttpBoundaryError
    ? jsonResponse(error.status, error.code, error.message, error.status === 405 ? { Allow: "GET, POST, DELETE" } : {})
    : jsonResponse(500, -32603, "Internal server error");
  return sendWebResponse(response, res, 64 * 1024);
}

async function handleRequest(req, res, configuration) {
  if (activeRequests.size >= configuration.concurrencyLimit) {
    await sendBoundaryError(new HttpBoundaryError(429, -32009, "Too many requests"), res);
    return;
  }
  const controller = new AbortController();
  activeRequests.add(controller);
  const abort = () => controller.abort();
  req.once("aborted", abort);
  res.once("close", () => {
    if (!res.writableEnded) abort();
  });
  let provisionalSession;
  try {
    const requestUrl = validateTransportBoundary(req, configuration);
    const auth = validateToken(req, configuration);
    const method = req.method?.toUpperCase() ?? "";
    if (!["GET", "POST", "DELETE"].includes(method)) {
      throw new HttpBoundaryError(405, -32000, "Method not allowed");
    }
    let body = Buffer.alloc(0);
    if (method === "POST") {
      const bodyTimer = setTimeout(() => controller.abort(), configuration.requestTimeoutMs);
      try {
        body = await readRequestBody(req, configuration.maxBodyBytes, controller.signal);
      } finally {
        clearTimeout(bodyTimer);
      }
    }
    const parsedBody = method === "POST" ? parseJsonBody(body) : undefined;
    if (parsedBody !== undefined) enforceMessageScopes(parsedBody, auth);
    const sessionId = req.headers["mcp-session-id"];
    const normalizedSessionId = Array.isArray(sessionId) ? undefined : sessionId;
    let session = normalizedSessionId ? sessions.get(normalizedSessionId) : undefined;
    if (normalizedSessionId && !session) throw new HttpBoundaryError(404, -32001, "Session not found");
    if (session && session.fingerprint !== auth.fingerprint) throw new HttpBoundaryError(403, -32000, "Forbidden");
    if (!session) {
      const messages = Array.isArray(parsedBody) ? parsedBody : [parsedBody];
      const initializing = method === "POST" && messages.length === 1 && messages[0]?.method === "initialize";
      if (!initializing) throw new HttpBoundaryError(400, -32600, "Mcp-Session-Id header is required");
      if (sessions.size >= configuration.concurrencyLimit) throw new HttpBoundaryError(429, -32009, "Too many sessions");
      provisionalSession = createSession();
      provisionalSession.fingerprint = auth.fingerprint;
      await provisionalSession.server.connect(provisionalSession.transport);
      session = provisionalSession;
    }
    const request = webRequest(req, requestUrl, body, controller.signal);
    const response = await transportResponse(session, request, parsedBody, configuration.requestTimeoutMs, controller);
    await sendWebResponse(response, res, configuration.maxResponseBytes);
    if (provisionalSession && !provisionalSession.id) await closeSession(provisionalSession);
  } catch (error) {
    if (provisionalSession && !provisionalSession.id) await closeSession(provisionalSession);
    if (!res.headersSent) await sendBoundaryError(error, res);
    else res.end();
  } finally {
    req.off("aborted", abort);
    activeRequests.delete(controller);
  }
}

const configuration = loadHttpConfiguration();
const httpServer = createHttpServer((req, res) => {
  void handleRequest(req, res, configuration);
});

let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const controller of activeRequests) controller.abort();
  await Promise.all([...sessions.values()].map((session) => closeSession(session)));
  await closeActiveChildren();
  await new Promise((resolve) => httpServer.close(resolve));
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    void shutdown().finally(() => process.exit(0));
  });
}

httpServer.on("clientError", (_error, socket) => {
  socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
});

httpServer.on("error", (error) => {
  const code = typeof error?.code === "string" ? error.code : "listener";
  process.stderr.write(`mcp-http-error ${code}\n`);
  process.exitCode = 1;
});

httpServer.listen(configuration.port, configuration.bind, () => {
  const address = httpServer.address();
  if (!address || typeof address === "string") {
    process.stderr.write("mcp-http-error listener\n");
    return;
  }
  process.stderr.write(`mcp-http-listening http://${configuration.bind}:${address.port}\n`);
});
