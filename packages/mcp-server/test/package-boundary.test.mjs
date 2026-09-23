import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { createHmac } from "node:crypto";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const repositoryRoot = resolve(packageRoot, "../..");
const httpSecret = "0123456789abcdef0123456789abcdef";
const httpIssuer = "https://issuer.example";
const httpAudience = "claude-obsidian";

function httpToken() {
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify({
    aud: httpAudience,
    exp: Math.floor(Date.now() / 1000) + 300,
    iss: httpIssuer,
    scope: "vault:read vault:write",
  })).toString("base64url");
  const signature = createHmac("sha256", httpSecret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function collectOutput(child) {
  let stdout = "";
  let stderr = "";
  let pendingStdout = "";
  const lines = [];
  const waiters = [];

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
    pendingStdout += chunk;
    let newline = pendingStdout.indexOf("\n");
    while (newline >= 0) {
      const line = pendingStdout.slice(0, newline).replace(/\r$/, "");
      pendingStdout = pendingStdout.slice(newline + 1);
      const waiter = waiters.shift();
      if (waiter) waiter.resolve(line);
      else lines.push(line);
      newline = pendingStdout.indexOf("\n");
    }
  });
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  const rejectWaiters = (error) => {
    for (const waiter of waiters.splice(0)) waiter.reject(error);
  };
  child.once("error", rejectWaiters);
  const closed = new Promise((resolveClose) => {
    child.once("close", (code, signal) => {
      rejectWaiters(new Error(`stdio launcher exited before responding: ${code ?? signal}`));
      resolveClose({ code, signal });
    });
  });

  return {
    closed,
    nextLine() {
      if (lines.length > 0) return Promise.resolve(lines.shift());
      return new Promise((resolveLine, reject) => waiters.push({ resolve: resolveLine, reject }));
    },
    get stdout() { return stdout; },
    get stderr() { return stderr; },
  };
}

function run(command, args, options) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code) => {
      if (code === 0) resolveRun({ stdout, stderr });
      else reject(new Error(`${command} exited with ${code}: ${stderr || stdout}`));
    });
  });
}

async function initialize(child, output, id = 1) {
  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id,
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "package-boundary-test", version: "1.0.0" },
    },
  })}\n`);
  const response = JSON.parse(await output.nextLine());
  assert.equal(response.jsonrpc, "2.0");
  assert.equal(response.id, id);
  assert.equal(response.result?.protocolVersion, "2025-11-25");
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
}

async function close(child, output) {
  child.stdin.end();
  let timeout;
  const closed = await Promise.race([
    output.closed,
    new Promise((_, reject) => {
      timeout = setTimeout(() => reject(new Error("stdio launcher did not stop after stdin closed")), 2000);
    }),
  ]).finally(() => clearTimeout(timeout));
  assert.equal(closed.code, 0);
  assert.equal(closed.signal, null);
}

function assertMcpOutput(output) {
  for (const [index, line] of output.stdout.split(/\r?\n/).entries()) {
    if (line.trim() === "") continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      assert.fail(`stdout line ${index + 1} is not JSON-RPC: ${line}`);
    }
    const isRequest = typeof message.method === "string";
    const isResponse = Object.hasOwn(message, "id")
      && (Object.hasOwn(message, "result") !== Object.hasOwn(message, "error"));
    assert.equal(message.jsonrpc, "2.0", `stdout line ${index + 1} is not JSON-RPC 2.0`);
    assert.ok(isRequest || isResponse, `stdout line ${index + 1} is not an MCP message`);
  }
  assert.equal(output.stderr, "");
}

test("packed package exposes a built stdio launcher that works outside the install directory", async (t) => {
  const packageManifest = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  assert.deepEqual(packageManifest.bin, {
    "claude-obsidian-mcp": "dist/stdio.mjs",
    "claude-obsidian-mcp-http": "dist/http.mjs",
  });

  const fixture = await mkdtemp(join(tmpdir(), "mcp-package-boundary-"));
  const installRoot = join(fixture, "install");
  const externalCwd = join(fixture, "external");
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(installRoot);
  await mkdir(externalCwd);
  await mkdir(vault);
  await mkdir(join(vault, "Journal", "Days"), { recursive: true });
  await run("git", ["init", "--quiet"], { cwd: externalCwd });
  await writeFile(join(vault, "note.md"), "# note\n");
  await writeFile(config, `---\nvault_path: ${vault}\ndaily_path: Journal/Days/\n---\n`);

  await run("npm", ["pack", "--silent", "--ignore-scripts", "--pack-destination", fixture], { cwd: packageRoot });
  const tarball = join(fixture, (await readdir(fixture)).find((name) => name.endsWith(".tgz")));
  await run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--prefix", installRoot, tarball], { cwd: externalCwd });

  const installedPackage = join(installRoot, "node_modules", "@claude-obsidian", "mcp-server");
  const launcher = join(installRoot, "node_modules", ".bin", "claude-obsidian-mcp");
  const httpLauncher = join(installRoot, "node_modules", ".bin", "claude-obsidian-mcp-http");
  const launcherStats = await stat(launcher);
  assert.ok((launcherStats.mode & 0o111) !== 0);
  assert.ok(((await stat(httpLauncher)).mode & 0o111) !== 0);
  await stat(join(installedPackage, "dist", "stdio.mjs"));
  await stat(join(installedPackage, "dist", "helpers", "lib", "resolve-config.sh"));
  await stat(join(installedPackage, "dist", "helpers", "commit-meta.sh"));

  const baseEnvironment = { ...process.env };
  delete baseEnvironment.MCP_REPOSITORY_ROOTS;
  const defaultChild = spawn(launcher, [], {
    cwd: externalCwd,
    env: { ...baseEnvironment, OBSIDIAN_LOCAL_MD: config },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const explicitChild = spawn(launcher, [], {
    cwd: externalCwd,
    env: { ...baseEnvironment, OBSIDIAN_LOCAL_MD: config, MCP_REPOSITORY_ROOTS: repositoryRoot },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const defaultOutput = collectOutput(defaultChild);
  const explicitOutput = collectOutput(explicitChild);
  t.after(async () => {
    if (defaultChild.exitCode === null) await close(defaultChild, defaultOutput);
    if (explicitChild.exitCode === null) await close(explicitChild, explicitOutput);
    await rm(fixture, { recursive: true, force: true });
  });

  await initialize(defaultChild, defaultOutput);
  defaultChild.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "obsidian_commit_meta", arguments: { repository: externalCwd } },
  })}\n`);
  const deniedMetadata = JSON.parse(await defaultOutput.nextLine());
  assert.equal(deniedMetadata.id, 2);
  assert.equal(deniedMetadata.result?.isError, true);
  assert.equal(JSON.parse(deniedMetadata.result.content[0].text).code, "PATH_INVALID");
  await close(defaultChild, defaultOutput);
  assertMcpOutput(defaultOutput);

  await initialize(explicitChild, explicitOutput);
  explicitChild.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: { name: "obsidian_commit_meta", arguments: { repository: repositoryRoot } },
  })}\n`);
  const metadata = JSON.parse(await explicitOutput.nextLine());
  assert.equal(metadata.id, 3);
  assert.equal(metadata.result?.isError, false);
  assert.equal(metadata.result?.structuredContent?.repository, "nhangen/claude-obsidian-plugin");
  explicitChild.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: { name: "obsidian_daily_append", arguments: { content: "Packaged stdio write", date: "2026-09-24", idempotency_key: "packaged-stdio-1" } },
  })}\n`);
  const stdioWrite = JSON.parse(await explicitOutput.nextLine());
  assert.equal(stdioWrite.result?.isError, false);
  assert.equal(stdioWrite.result?.structuredContent?.path, "Journal/Days/2026-09-24.md");
  assert.match(await readFile(join(vault, "Journal", "Days", "2026-09-24.md"), "utf8"), /Packaged stdio write/);
  await close(explicitChild, explicitOutput);
  assertMcpOutput(explicitOutput);

  const httpChild = spawn(httpLauncher, [], {
    cwd: externalCwd,
    env: {
      ...baseEnvironment,
      OBSIDIAN_LOCAL_MD: config,
      MCP_HTTP_BIND: "127.0.0.1",
      MCP_HTTP_PORT: "0",
      MCP_HTTP_JWT_SECRET: httpSecret,
      MCP_HTTP_JWT_ISSUER: httpIssuer,
      MCP_HTTP_JWT_AUDIENCE: httpAudience,
      MCP_HTTP_ALLOWED_HOSTS: "127.0.0.1,localhost",
      MCP_HTTP_ALLOWED_ORIGINS: "https://allowed.example",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let httpStderr = "";
  let readyResolve;
  const ready = new Promise((resolveReady) => { readyResolve = resolveReady; });
  httpChild.stderr.setEncoding("utf8");
  httpChild.stderr.on("data", (chunk) => {
    httpStderr += chunk;
    const match = httpStderr.match(/mcp-http-listening (http:\/\/127\.0\.0\.1:\d+)/);
    if (match) readyResolve(match[1]);
  });
  t.after(() => { if (httpChild.exitCode === null) httpChild.kill("SIGTERM"); });
  const httpUrl = await ready;
  const headers = {
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${httpToken()}`,
    "Content-Type": "application/json",
    Host: "127.0.0.1",
    Origin: "https://allowed.example",
  };
  const initialized = await fetch(`${httpUrl}/mcp`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      jsonrpc: "2.0", id: 10, method: "initialize",
      params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "package-boundary-test", version: "1" } },
    }),
  });
  const sessionId = initialized.headers.get("mcp-session-id");
  assert.equal(initialized.status, 200);
  const httpWrite = await fetch(`${httpUrl}/mcp`, {
    method: "POST",
    headers: { ...headers, "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 11, method: "tools/call",
      params: { name: "obsidian_daily_append", arguments: { content: "Packaged HTTP write", date: "2026-09-25", idempotency_key: "packaged-http-1" } },
    }),
  });
  assert.equal(httpWrite.status, 200);
  assert.equal((await httpWrite.json()).result?.structuredContent?.path, "Journal/Days/2026-09-25.md");
  assert.match(await readFile(join(vault, "Journal", "Days", "2026-09-25.md"), "utf8"), /Packaged HTTP write/);
  httpChild.kill("SIGTERM");
});

test("packed stdio and HTTP entrypoints serialize contended keeper writes", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-package-contention-"));
  const installRoot = join(fixture, "install");
  const externalCwd = join(fixture, "external");
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(installRoot);
  await mkdir(externalCwd);
  await mkdir(join(vault, ".obsidian"), { recursive: true });
  await mkdir(join(vault, "Journal", "Days"), { recursive: true });
  await mkdir(join(vault, "Inbox"), { recursive: true });
  await writeFile(config, `---\nvault_path: ${vault}\ndaily_path: Journal/Days/\n---\n`);

  await run("npm", ["pack", "--silent", "--ignore-scripts", "--pack-destination", fixture], { cwd: packageRoot });
  const tarball = join(fixture, (await readdir(fixture)).find((name) => name.endsWith(".tgz")));
  await run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--prefix", installRoot, tarball], { cwd: externalCwd });

  const installedPackage = join(installRoot, "node_modules", "@claude-obsidian", "mcp-server");
  const launcher = join(installRoot, "node_modules", ".bin", "claude-obsidian-mcp");
  const httpLauncher = join(installRoot, "node_modules", ".bin", "claude-obsidian-mcp-http");
  assert.ok(((await stat(join(installedPackage, "dist", "helpers", "keeper"))).mode & 0o111) !== 0);

  const children = new Set();
  t.after(async () => {
    for (const child of children) {
      if (child.exitCode === null) child.kill("SIGTERM");
    }
    await Promise.all([...children].map((child) => new Promise((resolveClose) => {
      if (child.exitCode !== null) resolveClose();
      else child.once("close", resolveClose);
    })));
    await rm(fixture, { recursive: true, force: true });
  });

  const environment = { ...process.env, OBSIDIAN_LOCAL_MD: config };
  delete environment.MCP_REPOSITORY_ROOTS;

  async function startStdio() {
    const child = spawn(launcher, [], {
      cwd: externalCwd,
      env: environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    children.add(child);
    const output = collectOutput(child);
    await initialize(child, output);
    return { child, output };
  }

  async function stdioCalls(server, calls) {
    for (const { id, name, args } of calls) {
      server.child.stdin.write(`${JSON.stringify({
        jsonrpc: "2.0",
        id,
        method: "tools/call",
        params: { name, arguments: args },
      })}\n`);
    }
    const responses = await Promise.all(calls.map(async () => JSON.parse(await server.output.nextLine())));
    assert.deepEqual(
      new Set(responses.map((response) => response.id)),
      new Set(calls.map((call) => call.id)),
    );
    return responses;
  }

  async function stdioCall(server, id, name, args) {
    return (await stdioCalls(server, [{ id, name, args }]))[0];
  }

  function writeOutcome(response) {
    return response.result?.structuredContent
      ?? JSON.parse(response.result.content[0].text);
  }

  await t.test("eight concurrent appends in one stdio daemon commit once", async () => {
    const server = await startStdio();
    const section = "## a1b2c3d4 — packaged single-daemon contention";
    const args = {
      content: "single daemon body",
      section,
      date: "2026-09-27",
      skip_if_hash: "a1b2c3d4",
      idempotency_key: "single-daemon-append",
    };

    const responses = await stdioCalls(server, Array.from({ length: 8 }, (_, index) => ({
      id: 100 + index,
      name: "obsidian_daily_append",
      args: {
        ...args,
        request_id: `single-daemon-${index}`,
      },
    })));
    const statuses = responses.map(writeOutcome).map((outcome) => outcome.status);
    assert.equal(statuses.filter((status) => status === "committed").length, 1);
    assert.equal(statuses.filter((status) => status === "skipped").length, 7);
    assert.equal(statuses.length, 8);

    const note = await readFile(join(vault, "Journal", "Days", "2026-09-27.md"), "utf8");
    assert.equal(note.split(section).length - 1, 1);
    await close(server.child, server.output);
    assertMcpOutput(server.output);
  });

  await t.test("two stdio daemons commit one shared append", async () => {
    const servers = await Promise.all([startStdio(), startStdio()]);
    const section = "## b2c3d4e5 — packaged two-daemon contention";
    const args = {
      content: "two daemon body",
      section,
      date: "2026-09-28",
      skip_if_hash: "b2c3d4e5",
      idempotency_key: "two-daemon-append",
    };

    const responses = await Promise.all(servers.map((server, index) =>
      stdioCall(server, 200 + index, "obsidian_daily_append", {
        ...args,
        request_id: `two-daemon-${index}`,
      })));
    const statuses = responses.map(writeOutcome).map((outcome) => outcome.status).sort();
    assert.deepEqual(statuses, ["committed", "skipped"]);

    const note = await readFile(join(vault, "Journal", "Days", "2026-09-28.md"), "utf8");
    assert.equal(note.split(section).length - 1, 1);
    for (const server of servers) {
      await close(server.child, server.output);
      assertMcpOutput(server.output);
    }
  });

  await t.test("stdio and HTTP expose one insert commit and one conflict", async () => {
    const stdio = await startStdio();
    const httpChild = spawn(httpLauncher, [], {
      cwd: externalCwd,
      env: {
        ...environment,
        MCP_HTTP_BIND: "127.0.0.1",
        MCP_HTTP_PORT: "0",
        MCP_HTTP_JWT_SECRET: httpSecret,
        MCP_HTTP_JWT_ISSUER: httpIssuer,
        MCP_HTTP_JWT_AUDIENCE: httpAudience,
        MCP_HTTP_ALLOWED_HOSTS: "127.0.0.1,localhost",
        MCP_HTTP_ALLOWED_ORIGINS: "https://allowed.example",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.add(httpChild);
    let httpStderr = "";
    let readyResolve;
    let readyReject;
    const ready = new Promise((resolveReady, rejectReady) => {
      readyResolve = resolveReady;
      readyReject = rejectReady;
    });
    httpChild.stderr.setEncoding("utf8");
    httpChild.stderr.on("data", (chunk) => {
      httpStderr += chunk;
      const match = httpStderr.match(/mcp-http-listening (http:\/\/127\.0\.0\.1:\d+)/);
      if (match) readyResolve(match[1]);
    });
    httpChild.once("error", readyReject);
    httpChild.once("close", (code) => {
      if (code !== 0) readyReject(new Error(`HTTP launcher exited with ${code}: ${httpStderr}`));
    });
    const httpUrl = await ready;
    const headers = {
      Accept: "application/json, text/event-stream",
      Authorization: `Bearer ${httpToken()}`,
      "Content-Type": "application/json",
      Host: "127.0.0.1",
      Origin: "https://allowed.example",
    };
    const initialized = await fetch(`${httpUrl}/mcp`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 300,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "package-contention-test", version: "1" } },
      }),
    });
    assert.equal(initialized.status, 200);
    const sessionId = initialized.headers.get("mcp-session-id");
    assert.ok(sessionId);
    const sessionHeaders = { ...headers, "MCP-Protocol-Version": "2025-11-25", "Mcp-Session-Id": sessionId };

    const shared = {
      title: "Contended Note",
      folder_hint: "Inbox",
      idempotency_key: "stdio-http-insert",
    };
    const [stdioResponse, httpResponse] = await Promise.all([
      stdioCall(stdio, 301, "obsidian_keeper_save", {
        ...shared,
        body: "body from stdio",
        request_id: "stdio-insert",
      }),
      fetch(`${httpUrl}/mcp`, {
        method: "POST",
        headers: sessionHeaders,
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 302,
          method: "tools/call",
          params: {
            name: "obsidian_keeper_save",
            arguments: { ...shared, body: "body from HTTP", request_id: "http-insert" },
          },
        }),
      }).then(async (response) => {
        assert.equal(response.status, 200);
        return response.json();
      }),
    ]);

    const outcomes = [writeOutcome(stdioResponse), writeOutcome(httpResponse)];
    assert.deepEqual(outcomes.map((outcome) => outcome.status).sort(), ["committed", "conflict"]);
    const conflict = outcomes.find((outcome) => outcome.status === "conflict");
    assert.equal(conflict.error_code, "IDEMPOTENCY_CONFLICT");
    assert.equal(conflict.retryable, false);

    const notes = (await readdir(join(vault, "Inbox"))).filter((name) => name.endsWith(".md") && name !== "INDEX.md");
    assert.deepEqual(notes, ["Contended Note.md"]);
    const index = await readFile(join(vault, "Inbox", "INDEX.md"), "utf8");
    assert.equal([...index.matchAll(/\[\[(?:Inbox\/)?Contended Note(?:[|#][^\]]*)?\]\]/g)].length, 1);

    await close(stdio.child, stdio.output);
    assertMcpOutput(stdio.output);
    httpChild.kill("SIGTERM");
    await new Promise((resolveClose) => httpChild.once("close", resolveClose));
  });
});

test("source entrypoint uses canonical helpers before a build exists", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-source-entrypoint-"));
  const sourceRoot = join(fixture, "checkout");
  const sourcePackage = join(sourceRoot, "packages", "mcp-server");
  const sourceDirectory = join(sourcePackage, "src");
  const packagedScriptLibrary = join(sourcePackage, "dist", "helpers", "lib");
  const scriptLibrary = join(sourceRoot, "scripts", "lib");
  const pluginDirectory = join(sourceRoot, ".claude-plugin");
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(sourceDirectory, { recursive: true });
  await mkdir(packagedScriptLibrary, { recursive: true });
  await mkdir(scriptLibrary, { recursive: true });
  await mkdir(pluginDirectory);
  await mkdir(vault);
  await copyFile(join(packageRoot, "src", "stdio.mjs"), join(sourceDirectory, "stdio.mjs"));
  await copyFile(join(repositoryRoot, "scripts", "lib", "resolve-config.sh"), join(scriptLibrary, "resolve-config.sh"));
  await copyFile(join(repositoryRoot, "scripts", "lib", "commit-capture-parse.sh"), join(scriptLibrary, "commit-capture-parse.sh"));
  await copyFile(join(repositoryRoot, "scripts", "commit-meta.sh"), join(sourceRoot, "scripts", "commit-meta.sh"));
  await copyFile(join(repositoryRoot, ".claude-plugin", "plugin.json"), join(pluginDirectory, "plugin.json"));
  await writeFile(join(packagedScriptLibrary, "resolve-config.sh"), "#!/usr/bin/env bash\nexit 91\n");
  await writeFile(join(sourcePackage, "dist", "helpers", "commit-meta.sh"), "#!/usr/bin/env bash\nexit 92\n");
  await symlink(join(packageRoot, "node_modules"), join(sourcePackage, "node_modules"), "dir");
  await writeFile(config, `---\nvault_path: ${vault}\n---\n`);
  await run("git", ["init", "--quiet"], { cwd: sourceRoot });
  await run("git", ["add", "."], { cwd: sourceRoot });
  await run("git", ["-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "source fixture"], {
    cwd: sourceRoot,
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Package Boundary Test",
      GIT_AUTHOR_EMAIL: "package-boundary@example.invalid",
      GIT_COMMITTER_NAME: "Package Boundary Test",
      GIT_COMMITTER_EMAIL: "package-boundary@example.invalid",
    },
  });

  const environment = { ...process.env };
  delete environment.MCP_REPOSITORY_ROOTS;

  const child = spawn(process.execPath, [join(sourceDirectory, "stdio.mjs")], {
    cwd: fixture,
    env: { ...environment, OBSIDIAN_LOCAL_MD: config },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const output = collectOutput(child);
  t.after(async () => {
    if (child.exitCode === null) await close(child, output);
    await rm(fixture, { recursive: true, force: true });
  });

  await initialize(child, output);
  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "obsidian_commit_meta", arguments: { repository: sourceRoot } },
  })}\n`);
  const metadata = JSON.parse(await output.nextLine());
  assert.equal(metadata.id, 2);
  assert.equal(metadata.result?.isError, false);
  assert.equal(metadata.result?.structuredContent?.repository, "local/checkout");
  assert.equal(metadata.result?.structuredContent?.subject, "source fixture");
  await close(child, output);
  assertMcpOutput(output);
});
