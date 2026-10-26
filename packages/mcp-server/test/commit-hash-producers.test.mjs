import assert from "node:assert/strict";
import { access } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { test } from "node:test";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");
let repositoryRoot = packageRoot;
try {
  repositoryRoot = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: packageRoot, encoding: "utf8" }).trim();
} catch {}

function run(command, args, environment = {}, cwd = repositoryRoot) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(command, args, {
      cwd,
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

const candidateHelpers = [
  join(packageRoot, "helpers", "commit-meta.sh"),
  join(packageRoot, "dist", "helpers", "commit-meta.sh"),
].filter(existsSync);

for (const helper of candidateHelpers) {
  test(`${helper.includes("dist") ? "dist" : "packaged"} commit-meta.sh emits full-width hash under normal and short core.abbrev`, async () => {
    await access(helper);
    const standard = await run("bash", [helper], {}, packageRoot);
    const hashMatch = standard.stdout.match(/\bhash=([0-9a-f]+)\b/);
    assert.ok(hashMatch, `expected hash in output: ${standard.stdout}`);
    assert.ok(hashMatch[1].length >= 40, `hash length must be >= 40, got ${hashMatch[1].length}`);

    const shortAbbrev = await run("bash", [helper], { GIT_CONFIG_PARAMETERS: "'core.abbrev=4'" }, packageRoot);
    const abbrevMatch = shortAbbrev.stdout.match(/\bhash=([0-9a-f]+)\b/);
    assert.ok(abbrevMatch, `expected hash in output: ${shortAbbrev.stdout}`);
    assert.ok(abbrevMatch[1].length >= 40, `hash length must be >= 40 even with core.abbrev=4, got ${abbrevMatch[1].length}`);
  });
}

const monorepoTestScript = join(repositoryRoot, "tests", "commit-meta.sh");
if (existsSync(monorepoTestScript)) {
  for (const [name, helper] of [
    ["source", join(repositoryRoot, "scripts", "commit-meta.sh")],
    ["maintained Codex package", join(repositoryRoot, "packages", "codex", "skills", "commit-capture", "scripts", "commit-meta.sh")],
    ["built MCP package", join(packageRoot, "dist", "helpers", "commit-meta.sh")],
  ]) {
    test(`${name} commit metadata emits full SHA-1 and SHA-256 identities`, async () => {
      await access(helper);
      const result = await run("bash", [monorepoTestScript], {
        COMMIT_META_UNDER_TEST: helper,
      });
      assert.match(result.stdout, /^ok   commit-meta\.sh/m);
    });
  }

  test("hook metadata remains full-width when core.abbrev is short", async () => {
    const result = await run("bash", [join(repositoryRoot, "tests", "commit-capture-head-gate.sh")]);
    assert.match(result.stdout, /^ok   commit-capture-head-gate\.sh/m);
  });
}
