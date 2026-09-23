import assert from "node:assert/strict";
import { chmod, copyFile, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");

function collect(child) {
  let buffer = "";
  const messages = [];
  let wake;
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    for (;;) {
      const newline = buffer.indexOf("\n");
      if (newline < 0) break;
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (line) messages.push(JSON.parse(line));
      wake?.();
      wake = undefined;
    }
  });
  return async (id) => {
    for (;;) {
      const message = messages.find((candidate) => candidate.id === id);
      if (message) return message;
      await new Promise((resolveWait) => { wake = resolveWait; });
    }
  };
}

test("built stdio fails closed on invalid or contradictory keeper results", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-write-protocol-"));
  const install = join(fixture, "install");
  const helperRoot = join(install, "dist", "helpers");
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(join(helperRoot, "lib"), { recursive: true });
  await mkdir(join(vault, "Daily"), { recursive: true });
  await copyFile(join(packageRoot, "dist", "stdio.mjs"), join(install, "dist", "stdio.mjs"));
  await copyFile(join(packageRoot, "dist", "helpers", "lib", "resolve-config.sh"), join(helperRoot, "lib", "resolve-config.sh"));
  await symlink(join(packageRoot, "node_modules"), join(install, "node_modules"), "dir");
  await writeFile(config, `---\nvault_path: ${vault}\ndaily_path: Daily/\n---\n`);
  await writeFile(join(helperRoot, "keeper"), `#!/usr/bin/env bash
case "$*" in
  *empty-key*) exit 0 ;;
  *malformed-key*) printf 'not-json\\n'; exit 0 ;;
  *multiple-key*) printf '%s\\n%s\\n' '{"status":"failed"}' '{"status":"failed"}'; exit 1 ;;
  *unknown-key*) printf '{"status":"mystery"}\\n'; exit 0 ;;
  *contradictory-key*) printf '{"status":"committed","request_id":"request-contradictory","idempotency_key":"contradictory-key","path":"Inbox/Test.md","affected_paths":["Inbox/Test.md"],"warnings":[],"recovery":{"required":false,"action":""},"error_code":null,"retryable":false}\\n'; exit 1 ;;
  *success-recovery-key*) printf '{"status":"committed","request_id":"request-success-recovery","idempotency_key":"success-recovery-key","path":"Inbox/Test.md","affected_paths":["Inbox/Test.md"],"warnings":[],"recovery":{"required":true,"action":"retry"},"error_code":null,"retryable":false}\\n'; exit 0 ;;
  *success-retryable-key*) printf '{"status":"skipped","request_id":"request-success-retryable","idempotency_key":"success-retryable-key","path":"Inbox/Test.md","affected_paths":["Inbox/Test.md"],"warnings":[],"recovery":{"required":false,"action":""},"error_code":null,"retryable":true}\\n'; exit 0 ;;
  *success-empty-path-key*) printf '{"status":"committed","request_id":"request-success-empty-path","idempotency_key":"success-empty-path-key","path":"","affected_paths":[],"warnings":[],"recovery":{"required":false,"action":""},"error_code":null,"retryable":false}\\n'; exit 0 ;;
  *success-error-key*) printf '{"status":"committed","request_id":"request-success-error","idempotency_key":"success-error-key","path":"Inbox/Test.md","affected_paths":["Inbox/Test.md"],"warnings":[],"recovery":{"required":false,"action":""},"error_code":"WRITE_FAILED","retryable":false}\\n'; exit 0 ;;
  *partial-no-recovery-key*) printf '{"status":"partial","request_id":"request-partial-no-recovery","idempotency_key":"partial-no-recovery-key","path":"Inbox/Test.md","affected_paths":["Inbox/Test.md"],"warnings":[],"recovery":{"required":false,"action":""},"error_code":"PARTIAL","retryable":true}\\n'; exit 2 ;;
  *conflict-retryable-key*) printf '{"status":"conflict","request_id":"request-conflict-retryable","idempotency_key":"conflict-retryable-key","path":"Inbox/Test.md","affected_paths":["Inbox/Test.md"],"warnings":[],"recovery":{"required":true,"action":"retry"},"error_code":"CONFLICT","retryable":true}\\n'; exit 3 ;;
  *failed-recovery-mismatch-key*) printf '{"status":"failed","request_id":"request-failed-recovery-mismatch","idempotency_key":"failed-recovery-mismatch-key","path":"Inbox/Test.md","affected_paths":["Inbox/Test.md"],"warnings":[],"recovery":{"required":true,"action":""},"error_code":"WRITE_FAILED","retryable":false}\\n'; exit 1 ;;
esac
exit 9
`);
  await chmod(join(helperRoot, "keeper"), 0o755);

  const child = spawn(process.execPath, [join(install, "dist", "stdio.mjs")], {
    cwd: fixture,
    env: { ...process.env, OBSIDIAN_LOCAL_MD: config },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const next = collect(child);
  t.after(async () => {
    if (child.exitCode === null) child.stdin.end();
    await once(child, "close").catch(() => {});
    await rm(fixture, { recursive: true, force: true });
  });

  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } },
  })}\n`);
  await next(1);
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);

  const cases = [
    "empty-key",
    "malformed-key",
    "multiple-key",
    "unknown-key",
    "contradictory-key",
    "success-recovery-key",
    "success-retryable-key",
    "success-empty-path-key",
    "success-error-key",
    "partial-no-recovery-key",
    "conflict-retryable-key",
    "failed-recovery-mismatch-key",
  ];
  for (const [index, idempotencyKey] of cases.entries()) {
    const id = index + 2;
    child.stdin.write(`${JSON.stringify({
      jsonrpc: "2.0", id, method: "tools/call",
      params: {
        name: "obsidian_keeper_save",
        arguments: { title: "Test", body: "Body", idempotency_key: idempotencyKey, request_id: `request-${idempotencyKey.replace("-key", "")}` },
      },
    })}\n`);
    const response = await next(id);
    assert.equal(response.result.isError, true, idempotencyKey);
    const result = JSON.parse(response.result.content[0].text);
    assert.equal(result.code, "KEEPER_PROTOCOL_ERROR", idempotencyKey);
    assert.equal(result.status, "failed", idempotencyKey);
    assert.equal(result.error_code, "KEEPER_PROTOCOL_ERROR", idempotencyKey);
    assert.equal(result.recovery.required, false, idempotencyKey);
    assert.equal(result.retryable, false, idempotencyKey);
  }
});
