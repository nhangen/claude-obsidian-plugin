import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { basename, join } from "node:path";

const commitPattern = /^[0-9a-f]{40}$/;
const digestPattern = /^[0-9a-f]{64}$/;

export function expectedReleaseTag(packageVersion) {
  if (typeof packageVersion !== "string" || packageVersion.length === 0) {
    throw new Error("package version must be a non-empty string");
  }
  return `mcp-v${packageVersion}`;
}

export function validateExactRevision(revision, packageVersion) {
  if (commitPattern.test(revision)) return;
  const expectedTag = expectedReleaseTag(packageVersion);
  if (revision !== expectedTag) {
    throw new Error(`revision must be a full commit SHA or ${expectedTag}`);
  }
}

export async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

export async function createReleaseMetadata({
  artifactPath,
  extractedPackageRoot,
  npmVersion,
  nodeVersion,
  sourceCommit,
}) {
  if (!commitPattern.test(sourceCommit)) {
    throw new Error("source commit must be a full lowercase commit SHA");
  }

  const packageManifest = JSON.parse(await readFile(join(extractedPackageRoot, "package.json"), "utf8"));
  const contractSha256 = await sha256File(join(extractedPackageRoot, "contract.json"));
  const artifactSha256 = await sha256File(artifactPath);

  if (!digestPattern.test(contractSha256) || !digestPattern.test(artifactSha256)) {
    throw new Error("release hashes must be SHA-256 digests");
  }

  return {
    schema_version: 1,
    source_commit: sourceCommit,
    package: {
      name: packageManifest.name,
      version: packageManifest.version,
    },
    contract_sha256: contractSha256,
    artifact: {
      filename: basename(artifactPath),
      sha256: artifactSha256,
    },
    tools: {
      node: nodeVersion,
      npm: npmVersion,
    },
  };
}

export function serializeReleaseMetadata(metadata) {
  return `${JSON.stringify(metadata, null, 2)}\n`;
}
