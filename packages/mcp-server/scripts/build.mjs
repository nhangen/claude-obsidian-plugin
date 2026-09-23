import { execFileSync } from "node:child_process";
import { chmod, copyFile, mkdir, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(packageRoot, "../..");
const outputRoot = join(packageRoot, "dist");
const helpers = [
  ["scripts/lib/resolve-config.sh", "helpers/lib/resolve-config.sh"],
  ["scripts/lib/commit-capture-parse.sh", "helpers/lib/commit-capture-parse.sh"],
  ["scripts/commit-meta.sh", "helpers/commit-meta.sh"],
  ["scripts/keeper", "helpers/keeper"],
  ["scripts/lib/note-hash.sh", "helpers/lib/note-hash.sh"],
  ["scripts/lib/vault-index.sh", "helpers/lib/vault-index.sh"],
  ["scripts/lib/allowlist-validate.sh", "helpers/lib/allowlist-validate.sh"],
  ["scripts/lib/dedup-scan.sh", "helpers/lib/dedup-scan.sh"],
];

await rm(outputRoot, { recursive: true, force: true });
execFileSync(process.execPath, [join(packageRoot, "node_modules", "typescript", "bin", "tsc"), "-p", join(packageRoot, "tsconfig.json")], {
  cwd: packageRoot,
  stdio: "inherit",
});

for (const [source, destination] of helpers) {
  const output = join(outputRoot, destination);
  await mkdir(dirname(output), { recursive: true });
  await copyFile(join(repositoryRoot, source), output);
  await chmod(output, (source.endsWith("commit-meta.sh") || source.endsWith("keeper")) ? 0o755 : 0o644);
}

await chmod(join(outputRoot, "stdio.mjs"), 0o755);
await chmod(join(outputRoot, "http.mjs"), 0o755);
