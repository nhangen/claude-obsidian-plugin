import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const packageVersion = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8")).version;
