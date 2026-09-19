import { spawn, spawnSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { readdir, readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, extname, isAbsolute, join, relative, resolve } from "node:path";
import { McpServer } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { z } from "zod";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(packageRoot, "../..");
const configResolver = join(repositoryRoot, "scripts", "lib", "resolve-config.sh");
const metadataScript = join(repositoryRoot, "scripts", "commit-meta.sh");
const maxResults = 5;
const maxPreviewLength = 240;
const maxFileBytes = 4 * 1024 * 1024;
const maxChildOutput = 64 * 1024;

function stderr(message) {
  process.stderr.write(`mcp-server: ${message}\n`);
}

function resolveConfigPath() {
  const result = spawnSync("bash", [configResolver], {
    encoding: "utf8",
    env: process.env,
    maxBuffer: 16 * 1024,
    timeout: 2_000,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error("Obsidian configuration could not be resolved");
  }
  const configPath = result.stdout.trim();
  if (!configPath) throw new Error("Obsidian configuration path is empty");
  return configPath;
}

function frontmatterValue(contents, key) {
  const lines = contents.split(/\r?\n/);
  if (lines[0]?.trim() !== "---") return "";
  for (const line of lines.slice(1)) {
    if (line.trim() === "---") break;
    const match = line.match(new RegExp(`^${key}:\\s*(.*)$`));
    if (!match) continue;
    const value = match[1].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      return value.slice(1, -1);
    }
    return value.replace(/\s+#.*$/, "").trim();
  }
  return "";
}

function configuredVault() {
  const configPath = resolveConfigPath();
  const config = readFileSync(configPath, "utf8");
  const vaultPath = frontmatterValue(config, "vault_path");
  if (!vaultPath) throw new Error("vault_path is missing from the Obsidian configuration");
  if (!isAbsolute(vaultPath)) throw new Error("vault_path must be an absolute path");
  const resolved = resolve(vaultPath);
  const details = statSync(resolved);
  if (!details.isDirectory()) throw new Error("configured vault_path is not a directory");
  return resolved;
}

async function collectMarkdownFiles(root, current = root, files = []) {
  const entries = await readdir(current, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.name === ".obsidian") continue;
    const path = join(current, entry.name);
    if (entry.isDirectory()) {
      await collectMarkdownFiles(root, path, files);
    } else if (entry.isFile() && extname(entry.name).toLowerCase() === ".md") {
      files.push(path);
    }
  }
  return files;
}

function preview(contents, query) {
  const lowered = query.toLowerCase();
  const lines = contents.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const relevant = lines.find((line) => line.toLowerCase().includes(lowered));
  return (relevant || lines[0] || "").slice(0, maxPreviewLength);
}

async function findNotes({ query }, vaultPath) {
  const lowered = query.toLowerCase();
  const files = await collectMarkdownFiles(vaultPath);
  const matches = [];
  for (const path of files) {
    const fileStat = await stat(path);
    if (fileStat.size > maxFileBytes) continue;
    const contents = await readFile(path, "utf8");
    const relativePath = relative(vaultPath, path).split("\\").join("/");
    const filenameMatch = relativePath.toLowerCase().includes(lowered);
    const contentMatch = contents.toLowerCase().includes(lowered);
    const tagMatch = /^tags:.*$/im.test(contents) && contents.match(/^tags:.*$/im)?.[0].toLowerCase().includes(lowered);
    if (!filenameMatch && !contentMatch && !tagMatch) continue;
    const occurrences = contents.toLowerCase().split(lowered).length - 1;
    matches.push({
      path: relativePath,
      preview: preview(contents, query),
      score: (filenameMatch ? 1_000_000 : 0) + (tagMatch ? 10_000 : 0) + occurrences * 100 + fileStat.mtimeMs,
    });
  }
  matches.sort((left, right) => right.score - left.score);
  return matches.slice(0, maxResults).map(({ path, preview: text }) => ({ path, preview: text }));
}

function commitMetadata(repository) {
  return new Promise((resolveResult, reject) => {
    if (!repository || !isAbsolute(repository)) {
      reject(new Error("repository must be an absolute path"));
      return;
    }
    const child = spawn("bash", [metadataScript, "-C", repository], {
      cwd: repositoryRoot,
      env: process.env,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderrOutput = "";
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      callback(value);
    };
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      finish(reject, new Error("commit metadata timed out"));
    }, 5_000);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      if (stdout.length > maxChildOutput) {
        child.kill("SIGTERM");
        finish(reject, new Error("commit metadata exceeded output limit"));
      }
    });
    child.stderr.on("data", (chunk) => {
      stderrOutput += chunk.toString();
      if (stderrOutput.length > maxChildOutput) child.kill("SIGTERM");
    });
    child.on("error", (error) => finish(reject, error));
    child.on("close", (code) => {
      if (code !== 0) {
        finish(reject, new Error(stderrOutput.trim() || `commit metadata exited with ${code}`));
        return;
      }
      const record = stdout.trim();
      if (!/^hash=[^|]+ \| branch=[^|]* \| files=[^|]* \| org_repo=[^|]+ \| repo_name=[^|]+ \| ticket=[^|]* \| date=[^|]+ \| time=[^|]+ \| vault_path=[^|]+ \| msg=.*/s.test(record)) {
        finish(reject, new Error("commit metadata returned an incomplete record"));
        return;
      }
      finish(resolveResult, record);
    });
  });
}

function textResult(value, isError = false) {
  return {
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) }],
    isError,
  };
}

function createServer() {
  const vaultPath = configuredVault();
  const server = new McpServer({ name: "claude-obsidian-mcp", version: "0.1.0" }, { capabilities: { tools: {} } });
  server.registerTool(
    "obsidian_find_notes",
    {
      title: "Find Obsidian notes",
      description: "Search the configured Obsidian vault without modifying it.",
      inputSchema: z.object({ query: z.string().trim().min(1).max(200) }),
    },
    async (args) => {
      try {
        return textResult(await findNotes(args, vaultPath));
      } catch (error) {
        return textResult(error instanceof Error ? error.message : String(error), true);
      }
    },
  );
  server.registerTool(
    "obsidian_commit_meta",
    {
      title: "Read commit metadata",
      description: "Read the existing sanitized commit metadata record for a repository.",
      inputSchema: z.object({ repository: z.string().trim().min(1) }),
    },
    async ({ repository }) => {
      try {
        return textResult(await commitMetadata(repository));
      } catch (error) {
        return textResult(error instanceof Error ? error.message : String(error), true);
      }
    },
  );
  return server;
}

const handle = serveStdio(createServer, {
  onerror: (error) => stderr(error instanceof Error ? error.message : String(error)),
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, async () => {
    await handle.close();
    process.exit(0);
  });
}
