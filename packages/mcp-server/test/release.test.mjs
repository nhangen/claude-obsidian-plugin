import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  createReleaseMetadata,
  expectedReleaseTag,
  releaseTagForRevision,
  serializeReleaseMetadata,
  validateExactRevision,
} from "../scripts/release-lib.mjs";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(packageRoot, "../..");

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

test("release revisions are exact commits or the package version tag", () => {
  assert.equal(expectedReleaseTag("0.1.0"), "mcp-v0.1.0");
  assert.doesNotThrow(() => validateExactRevision("a".repeat(40), "0.1.0"));
  assert.doesNotThrow(() => validateExactRevision("mcp-v0.1.0", "0.1.0"));
  assert.throws(() => validateExactRevision("master", "0.1.0"), /full commit SHA or mcp-v0\.1\.0/);
  assert.throws(() => validateExactRevision("mcp-v0.2.0", "0.1.0"), /full commit SHA or mcp-v0\.1\.0/);
  assert.equal(releaseTagForRevision("mcp-v0.1.0", "0.1.0"), "mcp-v0.1.0");
  assert.equal(releaseTagForRevision("a".repeat(40), "0.1.0"), undefined);
});

test("release metadata is derived from packed files and serializes deterministically", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-release-metadata-"));
  const extractedPackageRoot = join(fixture, "package");
  const artifactPath = join(fixture, "claude-obsidian-mcp-server-0.1.0.tgz");
  const contract = "{\"contract_version\":\"1.0.0\"}\n";
  const artifact = Buffer.from("packed artifact bytes");
  await mkdir(extractedPackageRoot);
  await writeFile(join(extractedPackageRoot, "package.json"), JSON.stringify({
    name: "@claude-obsidian/mcp-server",
    version: "0.1.0",
  }));
  await writeFile(join(extractedPackageRoot, "contract.json"), contract);
  await writeFile(artifactPath, artifact);
  t.after(() => rm(fixture, { recursive: true, force: true }));

  const metadata = await createReleaseMetadata({
    artifactPath,
    extractedPackageRoot,
    npmVersion: "11.6.0",
    nodeVersion: "v24.9.0",
    sourceCommit: "b".repeat(40),
  });

  const expected = {
    schema_version: 1,
    source_commit: "b".repeat(40),
    package: {
      name: "@claude-obsidian/mcp-server",
      version: "0.1.0",
    },
    contract_sha256: sha256(contract),
    artifact: {
      filename: "claude-obsidian-mcp-server-0.1.0.tgz",
      sha256: sha256(artifact),
    },
    tools: {
      node: "v24.9.0",
      npm: "11.6.0",
    },
  };
  assert.deepEqual(metadata, expected);
  assert.equal(serializeReleaseMetadata(metadata), `${JSON.stringify(expected, null, 2)}\n`);
});

test("release metadata records an exact release tag", async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), "mcp-release-tag-metadata-"));
  const extractedPackageRoot = join(fixture, "package");
  const artifactPath = join(fixture, "claude-obsidian-mcp-server-0.1.0.tgz");
  await mkdir(extractedPackageRoot);
  await writeFile(join(extractedPackageRoot, "package.json"), JSON.stringify({
    name: "@claude-obsidian/mcp-server",
    version: "0.1.0",
  }));
  await writeFile(join(extractedPackageRoot, "contract.json"), "{}\n");
  await writeFile(artifactPath, "artifact");
  t.after(() => rm(fixture, { recursive: true, force: true }));

  const metadata = await createReleaseMetadata({
    artifactPath,
    extractedPackageRoot,
    npmVersion: "11.6.0",
    nodeVersion: "v24.9.0",
    sourceCommit: "c".repeat(40),
    releaseTag: "mcp-v0.1.0",
  });

  assert.equal(metadata.release_tag, "mcp-v0.1.0");
  await assert.rejects(
    createReleaseMetadata({
      artifactPath,
      extractedPackageRoot,
      npmVersion: "11.6.0",
      nodeVersion: "v24.9.0",
      sourceCommit: "c".repeat(40),
      releaseTag: "mcp-v0.2.0",
    }),
    /release tag must be mcp-v0\.1\.0/,
  );
});

test("release workflow builds immutable revisions and only publishes pushed tags", async () => {
  const workflow = await readFile(join(repositoryRoot, ".github/workflows/mcp-release.yml"), "utf8");
  const publishJob = workflow.slice(workflow.indexOf("\n  publish:"));

  assert.match(workflow, /pull_request:/);
  assert.match(workflow, /inputs\.revision \|\| github\.sha/);
  assert.match(workflow, /inputs\.revision \|\| github\.event_name == 'push' && github\.ref_name \|\| github\.sha/);
  assert.match(workflow, /git merge-base --is-ancestor "\$GITHUB_SHA" origin\/master/);
  assert.match(publishJob, /if: github\.event_name == 'push' && startsWith\(github\.ref, 'refs\/tags\/mcp-v'\)/);
  assert.match(publishJob, /GitHub Release \$RELEASE_TAG already exists/);
  assert.doesNotMatch(publishJob, /gh release upload|--clobber/);
  assert.match(workflow, /# v8\.0\.1/);
});

test("release runner rechecks the worktree and rebuilds immediately before packing", async () => {
  const releaseScript = await readFile(join(packageRoot, "scripts/release.mjs"), "utf8");
  const testIndex = releaseScript.indexOf('run("npm", ["test"]);');
  const secondCleanIndex = releaseScript.indexOf("requireCleanWorktree();", testIndex);
  const buildIndex = releaseScript.indexOf('run("npm", ["run", "build"]);', secondCleanIndex);
  const packIndex = releaseScript.indexOf('run("npm", ["pack"', buildIndex);

  assert.ok(testIndex >= 0);
  assert.ok(secondCleanIndex > testIndex);
  assert.ok(buildIndex > secondCleanIndex);
  assert.ok(packIndex > buildIndex);
  assert.match(releaseScript, /releaseTag: releaseTagForRevision\(revision, sourceManifest\.version\)/);
});
