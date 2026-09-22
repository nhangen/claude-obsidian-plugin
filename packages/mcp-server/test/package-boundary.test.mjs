import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const launcher = join(packageRoot, "bin", "stdio.mjs");

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

test("package exposes stable stdio launcher and clean external startup", async (t) => {
  const packageManifest = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  assert.deepEqual(packageManifest.bin, {
    "claude-obsidian-mcp": "bin/stdio.mjs",
    "claude-obsidian-mcp-http": "bin/http.mjs",
  });
  const launcherStats = await stat(launcher);
  assert.ok((launcherStats.mode & 0o111) !== 0);

  const fixture = await mkdtemp(join(tmpdir(), "mcp-package-boundary-"));
  const vault = join(fixture, "vault");
  const config = join(fixture, "obsidian.local.md");
  await mkdir(vault);
  await writeFile(join(vault, "note.md"), "# note\n");
  await writeFile(config, `---\nvault_path: ${vault}\n---\n`);
  const child = spawn(process.execPath, [launcher], {
    cwd: tmpdir(),
    env: { ...process.env, OBSIDIAN_LOCAL_MD: config },
    stdio: ["pipe", "pipe", "pipe"],
  });
  t.after(async () => {
    child.stdin.end();
    await Promise.race([once(child, "close"), new Promise((resolveClose) => setTimeout(resolveClose, 500))]);
    await rm(fixture, { recursive: true, force: true });
  });

  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "package-boundary-test", version: "1.0.0" },
    },
  })}\n`);
  const response = JSON.parse(await waitForLine(child));
  assert.equal(response.jsonrpc, "2.0");
  assert.equal(response.id, 1);
  assert.equal(response.result?.protocolVersion, "2025-11-25");
  assert.equal(child.stderr.read()?.toString() ?? "", "");
});
