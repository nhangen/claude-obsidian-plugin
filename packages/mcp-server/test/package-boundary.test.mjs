import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const repositoryRoot = resolve(packageRoot, "../..");

function waitForLine(child) {
  return new Promise((resolveLine, reject) => {
    let output = "";
    const onData = (chunk) => {
      output += chunk;
      const newline = output.indexOf("\n");
      if (newline < 0) return;
      child.stdout.off("data", onData);
      resolveLine(output.slice(0, newline));
    };
    child.stdout.on("data", onData);
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      reject(new Error(`stdio launcher exited before responding: ${code ?? signal}`));
    });
  });
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

async function initialize(child, id = 1) {
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
  const response = JSON.parse(await waitForLine(child));
  assert.equal(response.jsonrpc, "2.0");
  assert.equal(response.id, id);
  assert.equal(response.result?.protocolVersion, "2025-11-25");
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
}

async function close(child) {
  child.stdin.end();
  await Promise.race([once(child, "close"), new Promise((resolveClose) => setTimeout(resolveClose, 500))]);
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
  await run("git", ["init", "--quiet"], { cwd: externalCwd });
  await writeFile(join(vault, "note.md"), "# note\n");
  await writeFile(config, `---\nvault_path: ${vault}\n---\n`);

  await run("npm", ["pack", "--silent", "--ignore-scripts", "--pack-destination", fixture], { cwd: packageRoot });
  const tarball = join(fixture, (await readdir(fixture)).find((name) => name.endsWith(".tgz")));
  await run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--prefix", installRoot, tarball], { cwd: externalCwd });

  const installedPackage = join(installRoot, "node_modules", "@claude-obsidian", "mcp-server");
  const launcher = join(installRoot, "node_modules", ".bin", "claude-obsidian-mcp");
  const launcherStats = await stat(launcher);
  assert.ok((launcherStats.mode & 0o111) !== 0);
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
  t.after(async () => {
    if (defaultChild.exitCode === null) await close(defaultChild);
    if (explicitChild.exitCode === null) await close(explicitChild);
    await rm(fixture, { recursive: true, force: true });
  });

  await initialize(defaultChild);
  defaultChild.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "obsidian_commit_meta", arguments: { repository: externalCwd } },
  })}\n`);
  const deniedMetadata = JSON.parse(await waitForLine(defaultChild));
  assert.equal(deniedMetadata.id, 2);
  assert.equal(deniedMetadata.result?.isError, true);
  assert.equal(JSON.parse(deniedMetadata.result.content[0].text).code, "PATH_INVALID");
  assert.equal(defaultChild.stderr.read()?.toString() ?? "", "");
  await close(defaultChild);

  await initialize(explicitChild);
  explicitChild.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: { name: "obsidian_commit_meta", arguments: { repository: repositoryRoot } },
  })}\n`);
  const metadata = JSON.parse(await waitForLine(explicitChild));
  assert.equal(metadata.id, 3);
  assert.equal(metadata.result?.isError, false);
  assert.equal(metadata.result?.structuredContent?.repository, "nhangen/claude-obsidian-plugin");
  assert.equal(explicitChild.stderr.read()?.toString() ?? "", "");
  await close(explicitChild);
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
  t.after(async () => {
    if (child.exitCode === null) await close(child);
    await rm(fixture, { recursive: true, force: true });
  });

  await initialize(child);
  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "obsidian_commit_meta", arguments: { repository: sourceRoot } },
  })}\n`);
  const metadata = JSON.parse(await waitForLine(child));
  assert.equal(metadata.id, 2);
  assert.equal(metadata.result?.isError, false);
  assert.equal(metadata.result?.structuredContent?.repository, "local/checkout");
  assert.equal(metadata.result?.structuredContent?.subject, "source fixture");
  assert.equal(child.stderr.read()?.toString() ?? "", "");
  await close(child);
});
