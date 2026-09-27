import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import {
  createReleaseMetadata,
  expectedReleaseTag,
  serializeReleaseMetadata,
  validateExactRevision,
} from "../scripts/release-lib.mjs";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

test("release revisions are exact commits or the package version tag", () => {
  assert.equal(expectedReleaseTag("0.1.0"), "mcp-v0.1.0");
  assert.doesNotThrow(() => validateExactRevision("a".repeat(40), "0.1.0"));
  assert.doesNotThrow(() => validateExactRevision("mcp-v0.1.0", "0.1.0"));
  assert.throws(() => validateExactRevision("master", "0.1.0"), /full commit SHA or mcp-v0\.1\.0/);
  assert.throws(() => validateExactRevision("mcp-v0.2.0", "0.1.0"), /full commit SHA or mcp-v0\.1\.0/);
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
