#!/usr/bin/env node

import { createHmac } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function issueToken({ secret, issuer, audience, subject = "mcp-monitor" }) {
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({
    aud: audience,
    exp: Math.floor(Date.now() / 1000) + 60,
    iss: issuer,
    scope: "vault:read repo:read",
    sub: subject,
  }));
  const signature = createHmac("sha256", secret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function initializeRequest() {
  return {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "claude-obsidian-mcp-monitor", version: "1.0.0" },
    },
  };
}

async function checkHealth() {
  const endpoint = process.env.MCP_MONITOR_URL?.trim() || "http://127.0.0.1:3000/mcp";
  const parsed = new URL(endpoint);
  const allowedOrigin = process.env.MCP_MONITOR_ORIGIN?.trim()
    || process.env.MCP_HTTP_ALLOWED_ORIGINS?.split(",")[0]?.trim()
    || `${parsed.protocol}//${parsed.host}`;
  const token = issueToken({
    secret: required("MCP_HTTP_JWT_SECRET"),
    issuer: required("MCP_HTTP_JWT_ISSUER"),
    audience: required("MCP_HTTP_JWT_AUDIENCE"),
  });
  let response;
  let sessionId;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      response = await fetch(endpoint, {
        method: "POST",
        headers: {
          Accept: "application/json, text/event-stream",
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
          Host: process.env.MCP_MONITOR_HOST?.trim() || parsed.host,
          Origin: allowedOrigin,
        },
        body: JSON.stringify(initializeRequest()),
        signal: AbortSignal.timeout(5_000),
      });
      sessionId = response.headers.get("mcp-session-id");
      break;
    } catch (error) {
      if (attempt === 2) throw new Error("health fetch failed after 3 attempts", { cause: error });
      await new Promise((resolve) => setTimeout(resolve, 250 * (attempt + 1)));
    }
  }
  try {
    const body = await response.text();
    if (!response.ok) throw new Error(`health HTTP ${response.status}`);
    if (Buffer.byteLength(body, "utf8") > 64 * 1024) throw new Error("health response too large");
    let parsedBody;
    try {
      parsedBody = JSON.parse(body);
    } catch {
      throw new Error("health response was not JSON");
    }
    const serverInfo = parsedBody?.result?.serverInfo;
    if (serverInfo?.name !== "claude-obsidian-mcp" || typeof serverInfo.version !== "string") {
      throw new Error("health response missing server identity");
    }
    const expectedVersion = process.env.MCP_MONITOR_EXPECTED_VERSION?.trim();
    if (expectedVersion && serverInfo.version !== expectedVersion) {
      throw new Error(`server version ${serverInfo.version} != ${expectedVersion}`);
    }
    return { version: serverInfo.version, protocol_version: parsedBody.result.protocolVersion };
  } finally {
    if (sessionId) {
      const closed = await fetch(endpoint, {
        method: "DELETE",
        headers: {
          Accept: "application/json, text/event-stream",
          Authorization: `Bearer ${token}`,
          Host: process.env.MCP_MONITOR_HOST?.trim() || parsed.host,
          Origin: allowedOrigin,
          "Mcp-Session-Id": sessionId,
        },
        signal: AbortSignal.timeout(5_000),
      });
      await closed.arrayBuffer();
      if (!closed.ok) throw new Error(`health session cleanup HTTP ${closed.status}`);
    }
  }
}

function aggregateUsage(output) {
  const events = output.split("\n").flatMap((line) => {
    if (!line.startsWith("mcp-http-request ")) return [];
    try {
      const event = JSON.parse(line.slice("mcp-http-request ".length));
      return event && typeof event === "object" ? [event] : [];
    } catch {
      return [];
    }
  });
  const durations = events
    .filter((event) => event.method !== "GET")
    .map((event) => event.duration_ms)
    .filter((value) => Number.isInteger(value) && value >= 0)
    .sort((left, right) => left - right);
  const p95Index = Math.max(0, Math.ceil(durations.length * 0.95) - 1);
  return {
    requests: events.length,
    successful_requests: events.filter((event) => event.status >= 200 && event.status < 400).length,
    failed_requests: events.filter((event) => event.status < 200 || event.status >= 400).length,
    tool_calls: events.filter((event) => typeof event.tool === "string").length,
    stream_requests: events.filter((event) => event.method === "GET").length,
    clients: [...new Set(events.map((event) => event.client_id).filter((value) => typeof value === "string"))].sort(),
    p95_duration_ms: durations.length ? durations[p95Index] : null,
  };
}

async function readUsage() {
  const service = process.env.MCP_MONITOR_SERVICE?.trim() || "claude-obsidian-mcp.service";
  const windowMinutes = Number(process.env.MCP_MONITOR_WINDOW_MINUTES || 15);
  if (!Number.isInteger(windowMinutes) || windowMinutes < 1 || windowMinutes > 1_440) {
    throw new Error("MCP_MONITOR_WINDOW_MINUTES must be 1-1440");
  }
  const { stdout } = await execFileAsync("journalctl", [
    "--user",
    "--unit",
    service,
    "--since",
    `${windowMinutes} minutes ago`,
    "--no-pager",
    "--output",
    "cat",
  ], { maxBuffer: 4 * 1024 * 1024 });
  return { window_minutes: windowMinutes, ...aggregateUsage(stdout) };
}

async function writeState(state) {
  const target = process.env.MCP_MONITOR_STATE_PATH?.trim()
    || `${homedir()}/.local/state/claude-obsidian-mcp/monitor.json`;
  const temporary = `${target}.tmp-${process.pid}`;
  await mkdir(dirname(target), { recursive: true, mode: 0o700 });
  await writeFile(temporary, `${JSON.stringify(state)}\n`, { mode: 0o600 });
  await rename(temporary, target);
}

export { aggregateUsage, checkHealth, issueToken, readUsage, writeState };

if (basename(process.argv[1] ?? "") === "monitor.mjs") {
  const checkedAt = new Date().toISOString();
  try {
    const health = await checkHealth();
    const usage = await readUsage();
    const state = { status: "ok", checked_at: checkedAt, ...health, ...usage };
    await writeState(state);
    process.stdout.write(`mcp-monitor ${JSON.stringify(state)}\n`);
  } catch (error) {
    const state = {
      status: "failed",
      checked_at: checkedAt,
      error: error instanceof Error ? error.message : "monitor failed",
    };
    await writeState(state).catch(() => {});
    process.stderr.write(`mcp-monitor ${JSON.stringify(state)}\n`);
    process.exitCode = 1;
  }
}
