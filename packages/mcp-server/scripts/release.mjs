import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createReleaseMetadata,
  serializeReleaseMetadata,
  validateExactRevision,
} from "./release-lib.mjs";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(packageRoot, "../..");
const outputRoot = join(packageRoot, "release");

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: options.cwd ?? packageRoot,
    encoding: options.encoding ?? "utf8",
    stdio: options.stdio ?? "inherit",
  });
}

function readRevisionArgument(argv) {
  const revisionIndex = argv.indexOf("--revision");
  if (revisionIndex < 0 || !argv[revisionIndex + 1] || revisionIndex + 2 !== argv.length) {
    throw new Error("usage: npm run release:bundle -- --revision <full-commit-sha|mcp-vVERSION>");
  }
  return argv[revisionIndex + 1];
}

const revision = readRevisionArgument(process.argv.slice(2));
const sourceManifest = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
validateExactRevision(revision, sourceManifest.version);

const sourceCommit = run("git", ["rev-parse", "HEAD"], { cwd: repositoryRoot, stdio: ["ignore", "pipe", "inherit"] }).trim();
const revisionCommit = run("git", ["rev-parse", `${revision}^{commit}`], { cwd: repositoryRoot, stdio: ["ignore", "pipe", "inherit"] }).trim();
if (sourceCommit !== revisionCommit) {
  throw new Error(`checked out commit ${sourceCommit} does not match revision ${revision} (${revisionCommit})`);
}
const worktreeStatus = run("git", ["status", "--porcelain", "--untracked-files=all"], {
  cwd: repositoryRoot,
  stdio: ["ignore", "pipe", "inherit"],
}).trim();
if (worktreeStatus !== "") {
  throw new Error("release bundles require a clean worktree");
}

run("npm", ["ci"]);
run("npm", ["test"]);

await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot);
const packOutput = JSON.parse(run("npm", ["pack", "--json", "--ignore-scripts", "--pack-destination", outputRoot], {
  stdio: ["ignore", "pipe", "inherit"],
}));
if (!Array.isArray(packOutput) || packOutput.length !== 1 || typeof packOutput[0].filename !== "string") {
  throw new Error("npm pack did not return exactly one artifact");
}

const artifactPath = join(outputRoot, packOutput[0].filename);
const extractionRoot = await mkdtemp(join(tmpdir(), "mcp-release-"));
try {
  run("tar", ["-xzf", artifactPath, "-C", extractionRoot]);
  const extractedPackageRoot = join(extractionRoot, "package");
  const packedManifest = JSON.parse(await readFile(join(extractedPackageRoot, "package.json"), "utf8"));
  if (packedManifest.version !== sourceManifest.version || packedManifest.name !== sourceManifest.name) {
    throw new Error("packed package identity does not match the source manifest");
  }

  const npmVersion = run("npm", ["--version"], { stdio: ["ignore", "pipe", "inherit"] }).trim();
  const metadata = await createReleaseMetadata({
    artifactPath,
    extractedPackageRoot,
    npmVersion,
    nodeVersion: process.version,
    sourceCommit,
  });
  const metadataName = `claude-obsidian-mcp-server-${packedManifest.version}.release.json`;
  await writeFile(join(outputRoot, metadataName), serializeReleaseMetadata(metadata));

  const files = (await readdir(outputRoot)).sort();
  process.stdout.write(`Release bundle:\n${files.map((name) => `  ${join(outputRoot, name)}`).join("\n")}\n`);
} finally {
  await rm(extractionRoot, { recursive: true, force: true });
}
