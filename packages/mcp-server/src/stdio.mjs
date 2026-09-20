import { spawn, spawnSync } from "node:child_process";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { readdir, readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, extname, isAbsolute, join, relative, resolve } from "node:path";
import { McpServer, ResourceTemplate } from "@modelcontextprotocol/server";
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
const maxResourceBytes = 64 * 1024;
const maxRepositoryPathCharacters = 4096;
const maxScanFiles = 10_000;
const subprocessTimeoutMs = 5_000;
const activeChildren = new Set();

function stderr(message) {
  process.stderr.write(`mcp-server: ${message}\n`);
}

function codedError(code, detail) {
  const error = new Error(detail);
  error.code = code;
  return error;
}

function throwIfAborted(signal) {
  if (signal?.aborted) throw codedError("CANCELLED", "request cancelled");
}

function resolveConfigPath() {
  const result = spawnSync("bash", [configResolver], {
    encoding: "utf8",
    env: process.env,
    maxBuffer: 16 * 1024,
    timeout: 2_000,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error("Obsidian configuration could not be resolved");
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
    if (value.startsWith('"') || value.startsWith("'")) {
      const quote = value[0];
      const closingQuote = value.indexOf(quote, 1);
      if (closingQuote < 0) return "";
      return value.slice(1, closingQuote);
    }
    return value.replace(/\s+#.*$/, "").trim();
  }
  return "";
}

function isContained(root, candidate) {
  const path = relative(root, candidate);
  return path === "" || (!path.startsWith("..") && !isAbsolute(path));
}

function loadConfiguration() {
  const configPath = resolveConfigPath();
  const config = readFileSync(configPath, "utf8");
  const vaultPath = frontmatterValue(config, "vault_path");
  if (!vaultPath) throw new Error("vault_path is missing from the Obsidian configuration");
  if (!isAbsolute(vaultPath)) throw new Error("vault_path must be an absolute path");
  const resolvedVault = realpathSync(resolve(vaultPath));
  if (!statSync(resolvedVault).isDirectory()) throw new Error("configured vault_path is not a directory");
  const dailyPath = frontmatterValue(config, "daily_path") || "Daily/";
  if (isAbsolute(dailyPath) || !isContained(resolvedVault, resolve(resolvedVault, dailyPath))) {
    throw new Error("daily_path must remain within the configured vault");
  }
  return { config, configPath, dailyPath: dailyPath.replace(/^\/+|\/+$/g, ""), vaultPath: resolvedVault };
}

async function collectMarkdownFiles(root, current = root, files = [], signal) {
  throwIfAborted(signal);
  const entries = await readdir(current, { withFileTypes: true });
  for (const entry of entries) {
    throwIfAborted(signal);
    if (entry.name === ".obsidian") continue;
    const path = join(current, entry.name);
    if (entry.isDirectory()) {
      await collectMarkdownFiles(root, path, files, signal);
    } else if (entry.isFile() && extname(entry.name).toLowerCase() === ".md") {
      files.push(path);
      if (files.length > maxScanFiles) throw codedError("SCAN_LIMIT", "vault scan exceeded file limit");
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

async function findNotes({ query }, vaultPath, signal) {
  throwIfAborted(signal);
  const lowered = query.toLowerCase();
  const files = await collectMarkdownFiles(vaultPath, vaultPath, [], signal);
  const matches = [];
  for (const path of files) {
    throwIfAborted(signal);
    const fileStat = await stat(path);
    if (fileStat.size > maxFileBytes) continue;
    const contents = await readFile(path, { encoding: "utf8", signal });
    const relativePath = relative(vaultPath, path).split("\\").join("/");
    const filenameMatch = relativePath.toLowerCase().includes(lowered);
    const contentMatch = contents.toLowerCase().includes(lowered);
    const tagLine = contents.match(/^tags:.*$/im)?.[0] || "";
    const tagMatch = tagLine.toLowerCase().includes(lowered);
    if (!filenameMatch && !contentMatch && !tagMatch) continue;
    const occurrences = contents.toLowerCase().split(lowered).length - 1;
    matches.push({
      path: relativePath,
      preview: preview(contents, query),
      score: (filenameMatch ? 1_000_000 : 0) + (tagMatch ? 10_000 : 0) + occurrences * 100,
    });
  }
  matches.sort((left, right) => right.score - left.score);
  return { matches: matches.slice(0, maxResults).map(({ path, preview: text }) => ({ path, preview: text })) };
}

async function terminateChild(child) {
  if (!child || child.exitCode !== null || child.signalCode) return;
  await new Promise((resolveChild) => {
    let settled = false;
    let hardTimer;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(hardTimer);
      resolveChild();
    };
    child.once("close", finish);
    try {
      if (process.platform === "win32") child.kill("SIGTERM");
      else process.kill(-child.pid, "SIGTERM");
    } catch {
      child.kill("SIGTERM");
    }
    hardTimer = setTimeout(() => {
      try {
        if (process.platform === "win32") child.kill("SIGKILL");
        else process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
      setTimeout(finish, 250);
    }, 250);
  });
}

function parseMetadataRecord(record) {
  const fields = Object.fromEntries(record.split(" | ").map((field) => {
    const separator = field.indexOf("=");
    return [field.slice(0, separator), field.slice(separator + 1)];
  }));
  const required = ["hash", "branch", "files", "org_repo", "ticket", "date", "time", "msg"];
  if (required.some((field) => !(field in fields))) {
    throw codedError("METADATA_INCOMPLETE", "commit metadata returned an incomplete record");
  }
  return {
    repository: fields.org_repo,
    branch: fields.branch,
    commit: fields.hash,
    files: fields.files,
    ticket: fields.ticket,
    date: fields.date,
    time: fields.time,
    subject: fields.msg,
  };
}

function commitMetadata(repository, signal) {
  if (!repository || !isAbsolute(repository) || repository.length > maxRepositoryPathCharacters) {
    return Promise.reject(codedError("PATH_INVALID", "repository must be an absolute path within the path limit"));
  }
  let canonicalRepository;
  try {
    canonicalRepository = realpathSync(repository);
    if (!statSync(canonicalRepository).isDirectory()) throw new Error("not a directory");
  } catch {
    return Promise.reject(codedError("PATH_INVALID", "repository is not an existing directory"));
  }
  throwIfAborted(signal);
  return new Promise((resolveResult, reject) => {
    const child = spawn("bash", [metadataScript, "-C", canonicalRepository], {
      cwd: repositoryRoot,
      env: process.env,
      detached: process.platform !== "win32",
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    activeChildren.add(child);
    let stdout = "";
    let stderrOutput = "";
    let settled = false;
    let stopping = false;
    let timer;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      activeChildren.delete(child);
      callback(value);
    };
    const onAbort = () => {
      stopping = true;
      void terminateChild(child).then(() => finish(reject, codedError("CANCELLED", "request cancelled")));
    };
    const stop = (error) => {
      if (settled || stopping) return;
      stopping = true;
      void terminateChild(child).then(() => finish(reject, error));
    };
    if (signal) {
      signal.addEventListener("abort", onAbort, { once: true });
      if (signal.aborted) onAbort();
    }
    timer = setTimeout(() => stop(codedError("SUBPROCESS_TIMEOUT", "commit metadata timed out")), subprocessTimeoutMs);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      if (Buffer.byteLength(stdout, "utf8") > maxChildOutput) stop(codedError("SUBPROCESS_OUTPUT_LIMIT", "commit metadata exceeded output limit"));
    });
    child.stderr.on("data", (chunk) => {
      stderrOutput += chunk.toString();
      if (Buffer.byteLength(stderrOutput, "utf8") > maxChildOutput) stop(codedError("SUBPROCESS_OUTPUT_LIMIT", "commit metadata exceeded output limit"));
    });
    child.on("error", (error) => {
      if (!stopping) finish(reject, codedError("READ_FAILED", error.message));
    });
    child.on("close", (code) => {
      if (stopping) return;
      if (code !== 0) {
        finish(reject, codedError("READ_FAILED", stderrOutput.trim() || `commit metadata exited with ${code}`));
        return;
      }
      try {
        finish(resolveResult, parseMetadataRecord(stdout.trim()));
      } catch (error) {
        finish(reject, error);
      }
    });
  });
}

async function readBounded(path, signal, maxBytes = maxResourceBytes) {
  throwIfAborted(signal);
  const details = await stat(path);
  if (details.size > maxBytes) throw codedError("SUBPROCESS_OUTPUT_LIMIT", "resource exceeded output limit");
  const contents = await readFile(path, { encoding: "utf8", signal });
  if (Buffer.byteLength(contents, "utf8") > maxBytes) throw codedError("SUBPROCESS_OUTPUT_LIMIT", "resource exceeded output limit");
  return contents;
}

function containedFile(root, path) {
  const candidate = resolve(root, path);
  if (!isContained(root, candidate)) throw codedError("PATH_INVALID", "resource path escapes the configured vault");
  try {
    const canonical = realpathSync(candidate);
    if (!isContained(root, canonical)) throw codedError("PATH_INVALID", "resource path escapes the configured vault");
    return canonical;
  } catch (error) {
    if (error.code === "PATH_INVALID") throw error;
    throw codedError("READ_FAILED", "resource does not exist");
  }
}

function resourceResult(uri, text, mimeType) {
  return { contents: [{ uri: uri.href, mimeType, text }] };
}

async function readResource(uri, variables, configuration, signal) {
  throwIfAborted(signal);
  if (uri.href === "obsidian://taxonomy") {
    const text = configuration.config.replace(/^vault_path:.*$/m, "vault_path: [redacted]");
    if (Buffer.byteLength(text, "utf8") > maxResourceBytes) throw codedError("SUBPROCESS_OUTPUT_LIMIT", "resource exceeded output limit");
    return resourceResult(uri, text, "text/plain");
  }
  if (uri.href === "obsidian://librarian") {
    return resourceResult(uri, await readBounded(containedFile(configuration.vaultPath, "Librarian.md"), signal), "text/markdown");
  }
  if (uri.href === "obsidian://pending") {
    return resourceResult(uri, await readBounded(containedFile(configuration.vaultPath, "Pending.md"), signal), "text/markdown");
  }
  const date = variables?.date;
  if (!date || !/^\d{4}-\d{2}-\d{2}$/.test(date)) throw codedError("PATH_INVALID", "daily resource date is invalid");
  const path = containedFile(configuration.vaultPath, join(configuration.dailyPath, `${date}.md`));
  return resourceResult(uri, await readBounded(path, signal), "text/markdown");
}

function successResult(value) {
  return { content: [{ type: "text", text: JSON.stringify(value) }], isError: false, structuredContent: value };
}

function errorResult(error) {
  const code = error?.code || "READ_FAILED";
  const detail = (error instanceof Error ? error.message : String(error)).slice(0, 240);
  return { content: [{ type: "text", text: JSON.stringify({ code, detail }) }], isError: true };
}

const searchOutput = z.strictObject({
  matches: z.array(z.strictObject({ path: z.string(), preview: z.string().max(maxPreviewLength) })).max(maxResults),
});
const metadataOutput = z.strictObject({
  repository: z.string(),
  branch: z.string(),
  commit: z.string(),
  files: z.string(),
  ticket: z.string(),
  date: z.string(),
  time: z.string(),
  subject: z.string(),
});

function createServer() {
  const configuration = loadConfiguration();
  const server = new McpServer(
    { name: "claude-obsidian-mcp", version: "0.1.0" },
    { capabilities: { tools: {}, resources: { listChanged: false } } },
  );
  server.registerTool(
    "obsidian_find_notes",
    {
      title: "Find Obsidian notes",
      description: "Search the configured Obsidian vault without modifying it.",
      inputSchema: z.strictObject({ query: z.string().trim().min(1).max(240) }),
      outputSchema: searchOutput,
    },
    async (args, ctx) => {
      try {
        return successResult(await findNotes(args, configuration.vaultPath, ctx.signal));
      } catch (error) {
        return errorResult(error);
      }
    },
  );
  server.registerTool(
    "obsidian_commit_meta",
    {
      title: "Read commit metadata",
      description: "Read sanitized commit metadata for an existing local repository.",
      inputSchema: z.strictObject({ repository: z.string().trim().min(1).max(maxRepositoryPathCharacters) }),
      outputSchema: metadataOutput,
    },
    async ({ repository }, ctx) => {
      try {
        return successResult(await commitMetadata(repository, ctx.signal));
      } catch (error) {
        return errorResult(error);
      }
    },
  );
  server.registerResource(
    "taxonomy",
    "obsidian://taxonomy",
    { title: "Obsidian taxonomy", description: "Redacted vault taxonomy configuration.", mimeType: "text/plain" },
    async (uri, ctx) => readResource(uri, undefined, configuration, ctx.signal),
  );
  server.registerResource(
    "librarian",
    "obsidian://librarian",
    { title: "Obsidian librarian index", description: "The vault librarian index.", mimeType: "text/markdown" },
    async (uri, ctx) => readResource(uri, undefined, configuration, ctx.signal),
  );
  server.registerResource(
    "pending",
    "obsidian://pending",
    { title: "Obsidian pending items", description: "Pending vault workflow items.", mimeType: "text/markdown" },
    async (uri, ctx) => readResource(uri, undefined, configuration, ctx.signal),
  );
  server.registerResource(
    "daily",
    new ResourceTemplate("obsidian://daily/{date}", { list: undefined }),
    { title: "Obsidian daily note", description: "A bounded daily note.", mimeType: "text/markdown" },
    async (uri, variables, ctx) => readResource(uri, variables, configuration, ctx.signal),
  );
  return server;
}

async function closeActiveChildren() {
  await Promise.all([...activeChildren].map((child) => terminateChild(child)));
}

const handle = serveStdio(createServer, { onerror: (error) => stderr(error instanceof Error ? error.message : String(error)) });
let shuttingDown = false;
async function shutdown(exit = false) {
  if (shuttingDown) return;
  shuttingDown = true;
  await closeActiveChildren();
  await handle.close();
  if (exit) process.exit(0);
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => void shutdown(true));
}
process.stdin.once("end", () => void shutdown(false));
