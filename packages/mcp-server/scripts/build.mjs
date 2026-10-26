import { execFileSync } from "node:child_process";
import { chmod, copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outputRoot = join(packageRoot, "dist");
const packageManifest = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
const helperSourceRoot = join(packageRoot, "helpers");
const helpers = [
  "lib/resolve-config.sh",
  "lib/commit-capture-parse.sh",
  "commit-meta.sh",
  "keeper",
  "lib/note-hash.sh",
  "lib/vault-index.sh",
  "lib/allowlist-validate.sh",
  "lib/dedup-scan.sh",
];

await rm(outputRoot, { recursive: true, force: true });
execFileSync(process.execPath, [join(packageRoot, "node_modules", "typescript", "bin", "tsc"), "-p", join(packageRoot, "tsconfig.json")], {
  cwd: packageRoot,
  stdio: "inherit",
});

for (const relativePath of helpers) {
  const source = join(helperSourceRoot, relativePath);
  const destination = join(outputRoot, "helpers", relativePath);
  await mkdir(dirname(destination), { recursive: true });
  await copyFile(source, destination);
  await chmod(destination, (relativePath.endsWith("commit-meta.sh") || relativePath.endsWith("keeper")) ? 0o755 : 0o644);
}

await chmod(join(outputRoot, "stdio.mjs"), 0o755);
await chmod(join(outputRoot, "http.mjs"), 0o755);
await writeFile(join(outputRoot, "version.mjs"), `export const packageVersion = ${JSON.stringify(packageManifest.version)};\n`);
