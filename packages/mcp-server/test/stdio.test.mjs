import assert from "node:assert/strict";
import { chmod, mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const entrypoint = join(packageRoot, "src", "stdio.mjs");
const repositoryRoot = resolve(packageRoot, "../..");

function startServer(configPath, extraEnv = {}) {
  const child = spawn(process.execPath, [entrypoint], {
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
    trailing: () => stdout,
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
            setTimeout(() => reject(new Error(`timed out waiting for MCP response ${id}`)), 2000);
          }),
        ]);
      }
    },
    notification(message) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    },
    messages,
  };
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

async function waitForFile(path, predicate, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const contents = await readFile(path, "utf8");
      if (predicate(contents)) return contents;
    } catch {
      // The marker is created by the child process under test.
    }
    await delay(25);
  }
  throw new Error(`timed out waiting for ${path}`);
}

test("stdio server exposes read-only tools with clean MCP framing", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-stdio-"));
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(vault);
  await writeFile(join(vault, "mcp-note.md"), "# MCP note\nThis fixture is searchable.\n");
  await writeFile(join(vault, "other.md"), "# Other note\n");
  await mkdir(join(vault, "Daily"));
  await writeFile(join(vault, "Daily", "2026-09-20.md"), "# Daily\nA daily resource.\n");
  await writeFile(join(vault, "Librarian.md"), "# Librarian\nAn index resource.\n");
  await writeFile(join(vault, "Pending.md"), "# Pending\n- [ ] A pending item\n");
  await writeFile(config, `---\nvault_path: "${vault}" # quoted config\ndaily_path: Daily/\napi_token: top-secret\n---\n\n# Obsidian Plugin Config\n\nVault is at \`${vault}\`.\n\n## Project Taxonomy\n\n| Domain | Vault path | Precedence | Notes |\n|--------|------------|------------|-------|\n| Development | Projects/Development/ | 10 | Code |\n`);

  const server = startServer(config);
  t.after(async () => {
    if (!server.child.killed) server.child.stdin.end();
    await Promise.race([
      once(server.child, "close").catch(() => {}),
      new Promise((resolveWait) => setTimeout(resolveWait, 100)),
    ]);
    await rm(fixture, { recursive: true, force: true });
  });

  const initialized = await server.request(
    {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-11-25",
        capabilities: {},
        clientInfo: { name: "stdio-contract-test", version: "1.0.0" },
      },
    },
    1,
  );
  assert.equal(initialized.jsonrpc, "2.0");
  assert.equal(initialized.id, 1);
  assert.equal(typeof initialized.result?.serverInfo?.name, "string");
  assert.equal(initialized.result?.protocolVersion, "2025-11-25");
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });

  const tools = await server.request(
    { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
    2,
  );
  const toolNames = tools.result.tools.map((tool) => tool.name);
  assert.deepEqual(toolNames.sort(), ["obsidian_commit_meta", "obsidian_find_notes"]);
  const searchTool = tools.result.tools.find((tool) => tool.name === "obsidian_find_notes");
  const metadataTool = tools.result.tools.find((tool) => tool.name === "obsidian_commit_meta");
  assert.equal(searchTool.outputSchema.properties.matches.type, "array");
  assert.equal(metadataTool.outputSchema.properties.commit.type, "string");

  const resources = await server.request(
    { jsonrpc: "2.0", id: 3, method: "resources/list", params: {} },
    3,
  );
  assert.deepEqual(
    resources.result.resources.map((resource) => resource.uri).sort(),
    ["obsidian://librarian", "obsidian://pending", "obsidian://taxonomy"],
  );

  const resourceTemplates = await server.request(
    { jsonrpc: "2.0", id: 4, method: "resources/templates/list", params: {} },
    4,
  );
  assert.deepEqual(resourceTemplates.result.resourceTemplates.map((resource) => resource.uriTemplate), ["obsidian://daily/{date}"]);

  const taxonomy = await server.request(
    { jsonrpc: "2.0", id: 5, method: "resources/read", params: { uri: "obsidian://taxonomy" } },
    5,
  );
  assert.equal(taxonomy.result.contents[0].mimeType, "text/plain");
  assert.doesNotMatch(taxonomy.result.contents[0].text, new RegExp(vault.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.doesNotMatch(taxonomy.result.contents[0].text, /top-secret/);
  assert.match(taxonomy.result.contents[0].text, /Project Taxonomy/);

  const librarian = await server.request(
    { jsonrpc: "2.0", id: 51, method: "resources/read", params: { uri: "obsidian://librarian" } },
    51,
  );
  assert.match(librarian.result.contents[0].text, /An index resource/);

  const pending = await server.request(
    { jsonrpc: "2.0", id: 52, method: "resources/read", params: { uri: "obsidian://pending" } },
    52,
  );
  assert.match(pending.result.contents[0].text, /A pending item/);

  const daily = await server.request(
    { jsonrpc: "2.0", id: 6, method: "resources/read", params: { uri: "obsidian://daily/2026-09-20" } },
    6,
  );
  assert.match(daily.result.contents[0].text, /A daily resource/);

  const search = await server.request(
    {
      jsonrpc: "2.0",
      id: 7,
      method: "tools/call",
      params: { name: "obsidian_find_notes", arguments: { query: "MCP" } },
    },
    7,
  );
  assert.equal(search.result?.isError, false);
  assert.equal(search.result?.structuredContent?.matches[0]?.path, "mcp-note.md");
  assert.match(search.result?.content?.[0]?.text ?? "", /mcp-note\.md/);

  const metadata = await server.request(
    {
      jsonrpc: "2.0",
      id: 8,
      method: "tools/call",
      params: {
        name: "obsidian_commit_meta",
        arguments: { repository: repositoryRoot },
      },
    },
    8,
  );
  assert.equal(metadata.result?.isError, false);
  assert.equal(metadata.result?.structuredContent?.repository, "nhangen/claude-obsidian-plugin");
  assert.equal(typeof metadata.result?.structuredContent?.commit, "string");
  assert.equal(typeof metadata.result?.structuredContent?.subject, "string");
  assert.doesNotMatch(metadata.result?.content?.[0]?.text ?? "", /vault_path=/);

  const beforeMutationAttempt = await readFile(join(vault, "mcp-note.md"), "utf8");
  const unavailableMutation = await server.request(
    {
      jsonrpc: "2.0",
      id: 80,
      method: "tools/call",
      params: { name: "obsidian_insert_note", arguments: { target: "mcp-note.md", body: "changed" } },
    },
    80,
  );
  assert.ok(unavailableMutation.error);
  assert.equal(await readFile(join(vault, "mcp-note.md"), "utf8"), beforeMutationAttempt);

  const outOfScope = await server.request(
    {
      jsonrpc: "2.0",
      id: 81,
      method: "tools/call",
      params: { name: "obsidian_commit_meta", arguments: { repository: tmpdir() } },
    },
    81,
  );
  assert.equal(outOfScope.result?.isError, true);
  assert.equal(JSON.parse(outOfScope.result.content[0].text).code, "PATH_INVALID");

  const invalid = await server.request(
    {
      jsonrpc: "2.0",
      id: 9,
      method: "tools/call",
      params: { name: "obsidian_find_notes", arguments: { query: "x".repeat(241) } },
    },
    9,
  );
  assert.equal(invalid.result?.isError, true);
  const invalidPayload = JSON.parse(invalid.result.content[0].text);
  assert.equal(invalidPayload.code, "INVALID_INPUT");
  assert.equal(typeof invalidPayload.detail, "string");
  assert.ok(invalidPayload.detail.length <= 240);

  server.notification({
    jsonrpc: "2.0",
    method: "notifications/cancelled",
    params: { requestId: 999, reason: "contract test" },
  });
  const afterCancellation = await server.request(
    { jsonrpc: "2.0", id: 10, method: "tools/list", params: {} },
    10,
  );
  assert.equal(afterCancellation.id, 10);

  const unknownMethod = await server.request(
    { jsonrpc: "2.0", id: 11, method: "not-a-real-method", params: {} },
    11,
  );
  assert.equal(unknownMethod.error?.code, -32601);
  assert.equal(server.child.exitCode, null);
  assert.equal(server.messages.some((message) => message.parseFailure), false);

  server.child.stdin.end();
  const [exitCode] = await once(server.child, "exit");
  assert.equal(exitCode, 0);
  assert.equal(server.messages.some((message) => message.parseFailure), false);
  assert.equal(server.trailing(), "");
  assert.doesNotMatch(server.stderr(), /stdout|MCP message/i);
});

test("cancellation stops active child work and shutdown reaps it", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-cancel-"));
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  const bin = join(fixture, "bin");
  const marker = join(fixture, "git-marker");
  await mkdir(vault);
  await mkdir(bin);
  await writeFile(join(bin, "git"), "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$MCP_GIT_MARKER\"\nsleep 4\nexit 0\n");
  await chmod(join(bin, "git"), 0o755);
  await writeFile(config, `---\nvault_path: ${vault}\n---\n`);

  const server = startServer(config, { PATH: `${bin}:${process.env.PATH}`, MCP_GIT_MARKER: marker });
  t.after(async () => {
    if (!server.child.killed) server.child.kill("SIGKILL");
    await Promise.race([once(server.child, "close").catch(() => {}), delay(500)]);
    await rm(fixture, { recursive: true, force: true });
  });

  await server.request(
    {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-11-25",
        capabilities: {},
        clientInfo: { name: "cancellation-test", version: "1.0.0" },
      },
    },
    1,
  );
  server.notification({ jsonrpc: "2.0", method: "notifications/initialized" });

  const pending = server.request(
    {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "obsidian_commit_meta", arguments: { repository: repositoryRoot } },
    },
    2,
  );
  const pendingHandled = pending.catch(() => {});
  const pidText = (await waitForFile(marker, (contents) => contents.trim().length > 0)).trim();
  await delay(100);
  server.notification({
    jsonrpc: "2.0",
    method: "notifications/cancelled",
    params: { requestId: 2, reason: "test cancellation" },
  });
  await delay(100);
  assert.equal(server.messages.some((message) => message.id === 2), false);
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      process.kill(Number(pidText), 0);
    } catch {
      break;
    }
    await delay(25);
  }
  assert.throws(() => process.kill(Number(pidText), 0));
  assert.equal(server.child.exitCode, null);
  server.child.stdin.end();
  await once(server.child, "close");
  await pendingHandled;
});

test("modern discovery and SIGTERM shutdown are covered separately", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-signal-"));
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  const bin = join(fixture, "bin");
  const marker = join(fixture, "git-marker");
  await mkdir(vault);
  await mkdir(bin);
  await writeFile(join(bin, "git"), "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$MCP_GIT_MARKER\"\nsleep 4\nexit 0\n");
  await chmod(join(bin, "git"), 0o755);
  await writeFile(config, `---\nvault_path: ${vault}\n---\n`);

  const server = startServer(config, { PATH: `${bin}:${process.env.PATH}`, MCP_GIT_MARKER: marker });
  t.after(async () => {
    if (!server.child.killed) server.child.kill("SIGKILL");
    await Promise.race([once(server.child, "close").catch(() => {}), delay(500)]);
    await rm(fixture, { recursive: true, force: true });
  });

  const discovery = await server.request(
    {
      jsonrpc: "2.0",
      id: 0,
      method: "server/discover",
      params: {
        _meta: {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": {},
        },
      },
    },
    0,
  );
  assert.ok(discovery.result, JSON.stringify(discovery));
  assert.ok(discovery.result.supportedVersions.includes("2026-07-28"));

  server.request(
    {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: {
        _meta: {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": {},
        },
        name: "obsidian_commit_meta",
        arguments: { repository: repositoryRoot },
      },
    },
    2,
  ).catch(() => {});
  await waitForFile(marker, (contents) => contents.trim().length > 0);
  server.child.kill("SIGTERM");
  const [exitCode] = await once(server.child, "exit");
  assert.equal(exitCode, 0);
});
