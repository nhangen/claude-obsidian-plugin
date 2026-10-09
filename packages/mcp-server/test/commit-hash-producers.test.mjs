import assert from "node:assert/strict";
import { access } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
const repositoryRoot = resolve(packageRoot, "../..");

function run(command, args, environment = {}) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(command, args, {
      cwd: repositoryRoot,
      env: { ...process.env, ...environment },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", rejectRun);
    child.once("close", (code) => {
      if (code === 0) resolveRun({ stdout, stderr });
      else rejectRun(new Error(`${command} ${args.join(" ")} exited with ${code}: ${stderr || stdout}`));
    });
  });
}

for (const [name, helper] of [
  ["source", join(repositoryRoot, "scripts", "commit-meta.sh")],
  ["maintained Codex package", join(repositoryRoot, "packages", "codex", "skills", "commit-capture", "scripts", "commit-meta.sh")],
  ["built MCP package", join(packageRoot, "dist", "helpers", "commit-meta.sh")],
]) {
  test(`${name} commit metadata emits full SHA-1 and SHA-256 identities`, async () => {
    await access(helper);
    const result = await run("bash", [join(repositoryRoot, "tests", "commit-meta.sh")], {
      COMMIT_META_UNDER_TEST: helper,
    });
    assert.match(result.stdout, /^ok   commit-meta\.sh/m);
  });
}

test("hook metadata remains full-width when core.abbrev is short", async () => {
  const result = await run("bash", [join(repositoryRoot, "tests", "commit-capture-head-gate.sh")]);
  assert.match(result.stdout, /^ok   commit-capture-head-gate\.sh/m);
});
