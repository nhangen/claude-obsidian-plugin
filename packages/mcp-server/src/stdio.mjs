#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { constants as fsConstants, existsSync, readFileSync, realpathSync, statSync, writeFileSync, rmSync, mkdtempSync } from "node:fs";
import { lstat, open, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { delimiter, dirname, extname, isAbsolute, join, relative, resolve } from "node:path";
import { McpServer, ResourceTemplate } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { z } from "zod";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceRepositoryRoot = resolve(packageRoot, "../..");
const sourcePackageRoot = join(sourceRepositoryRoot, "packages", "mcp-server");

function detectSourceCheckout() {
  try {
    const pluginManifest = JSON.parse(readFileSync(join(sourceRepositoryRoot, ".claude-plugin", "plugin.json"), "utf8"));
    return pluginManifest.name === "obsidian"
      && existsSync(join(sourceRepositoryRoot, ".git"))
      && realpathSync(packageRoot) === realpathSync(sourcePackageRoot)
      && existsSync(join(sourceRepositoryRoot, "scripts", "lib", "resolve-config.sh"))
      && existsSync(join(sourceRepositoryRoot, "scripts", "commit-meta.sh"));
  } catch {
    return false;
  }
}

const isSourceCheckout = detectSourceCheckout();
const packagedHelperRoot = join(packageRoot, "dist", "helpers");

function helperPath(...segments) {
  if (isSourceCheckout) return join(sourceRepositoryRoot, "scripts", ...segments);
  return join(packagedHelperRoot, ...segments);
}

const configResolver = helperPath("lib", "resolve-config.sh");
const metadataScript = helperPath("commit-meta.sh");
const keeperScript = helperPath("keeper");
const maxResults = 5;
const maxPreviewLength = 240;
const maxFileBytes = 4 * 1024 * 1024;
const maxChildOutput = 64 * 1024;
const maxResourceBytes = 64 * 1024;
const maxRepositoryPathCharacters = 4096;
const maxScanEntries = 10_000;
const maxScanBytes = 64 * 1024 * 1024;
const subprocessTimeoutMs = 5_000;
const protocolVersions = ["2026-07-28", "2025-11-25"];
const activeChildren = new Set();

function stderr(message) {
  process.stderr.write(`mcp-server: ${message}\n`);
}

function codedError(code, detail) {
  const error = new Error(detail);
  error.code = code;
  return error;
}

function childEnvironment() {
  const allowed = ["PATH", "HOME", "XDG_CONFIG_HOME", "OBSIDIAN_LOCAL_MD", "CLAUDE_PLUGIN_ROOT", "LANG", "LC_ALL", "MCP_GIT_MARKER"];
  return Object.fromEntries(allowed.filter((key) => process.env[key] !== undefined).map((key) => [key, process.env[key]]));
}

function throwIfAborted(signal) {
  if (signal?.aborted) throw codedError("CANCELLED", "request cancelled");
}

function resolveConfigPath() {
  const result = spawnSync("bash", [configResolver], {
    encoding: "utf8",
    env: childEnvironment(),
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
  const configuredRoots = process.env.MCP_REPOSITORY_ROOTS?.split(delimiter).filter(Boolean);
  const defaultRoots = isSourceCheckout ? [sourceRepositoryRoot] : [];
  const repositoryRoots = (configuredRoots?.length ? configuredRoots : defaultRoots).map((root) => {
    try {
      const canonical = realpathSync(resolve(root));
      if (!statSync(canonical).isDirectory()) throw new Error("not a directory");
      return canonical;
    } catch {
      throw new Error("MCP_REPOSITORY_ROOTS contains an invalid directory");
    }
  });
  return { config, configPath, dailyPath: dailyPath.replace(/^\/+|\/+$/g, ""), repositoryRoots, vaultPath: resolvedVault };
}

async function collectMarkdownFiles(root, current = root, files = [], signal, state = { entries: 0, bytes: 0 }) {
  throwIfAborted(signal);
  const entries = await readdir(current, { withFileTypes: true });
  for (const entry of entries) {
    throwIfAborted(signal);
    if (entry.name === ".obsidian") continue;
    const path = join(current, entry.name);
    state.entries += 1;
    if (state.entries > maxScanEntries) throw codedError("SCAN_LIMIT", "vault scan exceeded entry limit");
    let details;
    try {
      details = await lstat(path);
    } catch (error) {
      if (error.code === "ENOENT") continue;
      throw codedError("READ_FAILED", "vault entry could not be inspected");
    }
    if (details.isDirectory()) {
      await collectMarkdownFiles(root, path, files, signal, state);
    } else if (details.isFile() && extname(entry.name).toLowerCase() === ".md") {
      state.bytes += details.size;
      if (state.bytes > maxScanBytes) throw codedError("SCAN_LIMIT", "vault scan exceeded byte limit");
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

async function findNotes({ query }, vaultPath, signal) {
  throwIfAborted(signal);
  const lowered = query.toLowerCase();
  const files = await collectMarkdownFiles(vaultPath, vaultPath, [], signal);
  const matches = [];
  for (const path of files) {
    throwIfAborted(signal);
    const contents = await readRegularFile(path, signal, maxFileBytes, true);
    if (contents === null) continue;
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
  const repository = fields.org_repo.replace(/[?#].*$/, "");
  if (!repository || repository.includes("..") || repository.startsWith("/") || !repository.includes("/")) {
    throw codedError("METADATA_INCOMPLETE", "commit metadata returned an unsafe repository name");
  }
  return {
    repository,
    branch: fields.branch,
    commit: fields.hash,
    files: fields.files,
    ticket: fields.ticket,
    date: fields.date,
    time: fields.time,
    subject: fields.msg,
  };
}

function commitMetadata(repository, approvedRoots, signal) {
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
  if (!approvedRoots.some((root) => isContained(root, canonicalRepository))) {
    return Promise.reject(codedError("PATH_INVALID", "repository is outside the approved roots"));
  }
  throwIfAborted(signal);
  return new Promise((resolveResult, reject) => {
    const child = spawn("bash", [metadataScript, "-C", canonicalRepository], {
      cwd: canonicalRepository,
      env: childEnvironment(),
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

function makeVaultRelative(vaultPath, fullPath) {
  if (!fullPath) return "";
  if (isAbsolute(fullPath) && isContained(vaultPath, fullPath)) {
    return relative(vaultPath, fullPath).split("\\").join("/");
  }
  return fullPath.split("\\").join("/");
}

async function executeKeeperWrite(args, bodyContent, vaultPath, signal, targetPathHint) {
  throwIfAborted(signal);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--target" && args[i + 1]) {
      const relTarget = args[i + 1];
      if (relTarget.includes("..") || relTarget.startsWith("/")) {
        throw codedError("PATH_INVALID", "requested path is not allowed");
      }
    }
  }
  const tempDir = mkdtempSync(join(tmpdir(), "mcp-keeper-"));
  const bodyFile = join(tempDir, "body.md");
  try {
    writeFileSync(bodyFile, bodyContent, "utf8");
    const fullArgs = [...args, "--body-file", bodyFile, "--format", "json"];
    return await new Promise((resolveResult, reject) => {
      const child = spawn("bash", [keeperScript, ...fullArgs], {
        env: childEnvironment(),
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
      timer = setTimeout(() => stop(codedError("SUBPROCESS_TIMEOUT", "keeper write timed out")), subprocessTimeoutMs);
      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
        if (Buffer.byteLength(stdout, "utf8") > maxChildOutput) stop(codedError("SUBPROCESS_OUTPUT_LIMIT", "keeper exceeded output limit"));
      });
      child.stderr.on("data", (chunk) => {
        stderrOutput += chunk.toString();
        if (Buffer.byteLength(stderrOutput, "utf8") > maxChildOutput) stop(codedError("SUBPROCESS_OUTPUT_LIMIT", "keeper exceeded output limit"));
      });
      child.on("error", (error) => {
        if (!stopping) finish(reject, codedError("WRITE_FAILED", error.message));
      });
      child.on("close", (code) => {
        if (stopping) return;
        let parsed = null;
        try {
          parsed = JSON.parse(stdout.trim());
        } catch {}
        if (code !== 0) {
          if (stderrOutput.includes("must be vault-relative") || stderrOutput.includes("escapes the configured vault") || stderrOutput.includes("refusing symlink") || stderrOutput.includes("must not contain")) {
            finish(reject, codedError("PATH_INVALID", stderrOutput.trim() || "requested path is not allowed"));
            return;
          }
          if (parsed?.status === "conflict" || stderrOutput.includes("already exists") || stderrOutput.includes("conflict")) {
            finish(reject, codedError("CONFLICT", stderrOutput.trim() || "write conflict"));
            return;
          }
          if (parsed?.status === "partial") {
            finish(reject, codedError("PARTIAL", stderrOutput.trim() || "partial write occurred"));
            return;
          }
          finish(reject, codedError("WRITE_FAILED", stderrOutput.trim() || `keeper exited with code ${code}`));
          return;
        }
        const resolvedPath = parsed?.path ? makeVaultRelative(vaultPath, parsed.path) : targetPathHint;
        if (parsed?.status) {
          finish(resolveResult, { status: parsed.status, path: resolvedPath });
        } else {
          finish(resolveResult, { status: "committed", path: resolvedPath });
        }
      });
    });
  } finally {
    try { rmSync(tempDir, { recursive: true, force: true }); } catch {}
  }
}

async function keeperSave({ title, body, folder_hint, type, links }, vaultPath, signal) {
  let targetFolder = "Inbox";
  if (folder_hint && folder_hint.trim()) {
    targetFolder = folder_hint.trim().replace(/^\/+|\/+$/g, "");
  }
  const cleanTitle = title.trim().replace(/\.md$/i, "");
  const targetPath = `${targetFolder}/${cleanTitle}.md`;

  let formattedBody = body;
  const headerLines = [];
  if (type) headerLines.push(`type: ${type}`);
  if (links && links.length > 0) headerLines.push(`links: ${links.join(", ")}`);
  if (headerLines.length > 0) {
    formattedBody = `---\n${headerLines.join("\n")}\n---\n\n${body}`;
  }

  return executeKeeperWrite(
    ["insert", "--vault", vaultPath, "--target", targetPath, "--title", cleanTitle],
    formattedBody,
    vaultPath,
    signal,
    targetPath
  );
}

async function dailyAppend({ content, section, date, skip_if_hash }, vaultPath, dailyPath, signal) {
  const targetDate = date || new Date().toISOString().slice(0, 10);
  const targetPath = `${(dailyPath || "Daily/").replace(/\/+$/, "")}/${targetDate}.md`;
  const args = ["append", "--vault", vaultPath, "--date", targetDate];
  if (section) args.push("--section", section);
  if (skip_if_hash) args.push("--skip-if-hash", skip_if_hash);
  return executeKeeperWrite(args, content, vaultPath, signal, targetPath);
}

async function readBounded(path, signal, maxBytes = maxResourceBytes) {
  throwIfAborted(signal);
  return readRegularFile(path, signal, maxBytes);
}

async function readRegularFile(path, signal, maxBytes, skipOversize = false) {
  throwIfAborted(signal);
  let handle;
  try {
    handle = await open(path, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0));
    const details = await handle.stat();
    if (!details.isFile()) throw codedError("READ_FAILED", "resource is not a regular file");
    if (details.size > maxBytes) {
      if (skipOversize) return null;
      throw codedError("SUBPROCESS_OUTPUT_LIMIT", "resource exceeded output limit");
    }
    const contents = await handle.readFile({ encoding: "utf8", signal });
    throwIfAborted(signal);
    if (Buffer.byteLength(contents, "utf8") > maxBytes) {
      if (skipOversize) return null;
      throw codedError("SUBPROCESS_OUTPUT_LIMIT", "resource exceeded output limit");
    }
    return contents;
  } catch (error) {
    if (skipOversize && ["ENOENT", "ENOTDIR", "ELOOP"].includes(error?.code)) return null;
    if (error?.code === "ELOOP") throw codedError("PATH_INVALID", "resource path is a symlink");
    if (error?.code && ["PATH_INVALID", "READ_FAILED", "SUBPROCESS_OUTPUT_LIMIT", "CANCELLED"].includes(error.code)) throw error;
    throw codedError("READ_FAILED", "resource could not be read");
  } finally {
    await handle?.close().catch(() => {});
  }
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

function taxonomyText(configuration) {
  const lines = configuration.config.split(/\r?\n/);
  const heading = lines.findIndex((line) => line.trim() === "## Project Taxonomy");
  if (heading < 0) return "## Project Taxonomy\n";
  const table = lines.slice(heading + 1).filter((line) => line.trim().startsWith("|"));
  return ["## Project Taxonomy", ...table].join("\n") + "\n";
}

async function readResource(uri, variables, configuration, signal) {
  throwIfAborted(signal);
  if (uri.href === "obsidian://taxonomy") {
    const text = taxonomyText(configuration);
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
  const text = JSON.stringify(value);
  if (Buffer.byteLength(text, "utf8") > maxChildOutput) throw codedError("SUBPROCESS_OUTPUT_LIMIT", "tool output exceeded output limit");
  return { content: [{ type: "text", text }], isError: false, structuredContent: value };
}

function errorResult(error) {
  const knownCodes = new Set([
    "INVALID_INPUT", "PATH_INVALID", "READ_FAILED", "SCAN_LIMIT",
    "METADATA_INCOMPLETE", "SUBPROCESS_TIMEOUT", "SUBPROCESS_OUTPUT_LIMIT",
    "CANCELLED", "FORBIDDEN", "CONFLICT", "PARTIAL", "WRITE_FAILED"
  ]);
  const code = knownCodes.has(error?.code) ? error.code : "READ_FAILED";
  const detail = {
    INVALID_INPUT: "invalid tool input",
    PATH_INVALID: "requested path is not allowed",
    FORBIDDEN: "insufficient scope",
    CONFLICT: "write conflict",
    PARTIAL: "partial write occurred",
    WRITE_FAILED: "write failed",
    READ_FAILED: "read failed",
    SCAN_LIMIT: "vault scan limit exceeded",
    METADATA_INCOMPLETE: "commit metadata was incomplete",
    SUBPROCESS_TIMEOUT: "subprocess timed out",
    SUBPROCESS_OUTPUT_LIMIT: "output limit exceeded",
    CANCELLED: "request cancelled",
  }[code];
  return { content: [{ type: "text", text: JSON.stringify({ code, detail }) }], isError: true };
}

function parseToolInput(schema, args) {
  const result = schema.safeParse(args);
  if (!result.success) throw codedError("INVALID_INPUT", "invalid tool input");
  return result.data;
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
const writeOutput = z.strictObject({
  status: z.enum(["committed", "skipped", "conflict", "partial", "failed"]),
  path: z.string(),
});

const searchInput = z.strictObject({ query: z.string().trim().min(1).max(240) });
const metadataInput = z.strictObject({ repository: z.string().trim().min(1).max(maxRepositoryPathCharacters) });
const keeperSaveInput = z.strictObject({
  title: z.string().trim().min(1).max(240),
  body: z.string().min(1).max(65536),
  folder_hint: z.string().max(1024).optional(),
  type: z.string().max(100).optional(),
  links: z.array(z.string()).max(20).optional(),
});

const dailyAppendInput = z.strictObject({
  content: z.string().min(1).max(65536),
  section: z.string().max(240).optional(),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  skip_if_hash: z.string().regex(/^[0-9a-fA-F]+$/).optional(),
});

export function createServer({ supportedProtocolVersions = protocolVersions } = {}) {
  const configuration = loadConfiguration();
  const server = new McpServer(
    { name: "claude-obsidian-mcp", version: "0.1.0" },
    { capabilities: { tools: {}, resources: { listChanged: false } }, supportedProtocolVersions },
  );
  server.registerTool(
    "obsidian_find_notes",
    {
      title: "Find Obsidian notes",
      description: "Search the configured Obsidian vault without modifying it.",
      inputSchema: z.unknown(),
      outputSchema: searchOutput,
    },
    async (args, ctx) => {
      try {
        return successResult(await findNotes(parseToolInput(searchInput, args), configuration.vaultPath, ctx.mcpReq.signal));
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
      inputSchema: z.unknown(),
      outputSchema: metadataOutput,
    },
    async (args, ctx) => {
      try {
        const { repository } = parseToolInput(metadataInput, args);
        return successResult(await commitMetadata(repository, configuration.repositoryRoots, ctx.mcpReq.signal));
      } catch (error) {
        return errorResult(error);
      }
    },
  );
  server.registerTool(
    "obsidian_keeper_save",
    {
      title: "Save Obsidian note",
      description: "Save a structured note to the Obsidian vault.",
      inputSchema: z.unknown(),
      outputSchema: writeOutput,
    },
    async (args, ctx) => {
      try {
        const input = parseToolInput(keeperSaveInput, args);
        return successResult(await keeperSave(input, configuration.vaultPath, ctx.mcpReq.signal));
      } catch (error) {
        return errorResult(error);
      }
    },
  );
  server.registerTool(
    "obsidian_daily_append",
    {
      title: "Append to daily note",
      description: "Append a section to today's daily note in the Obsidian vault.",
      inputSchema: z.unknown(),
      outputSchema: writeOutput,
    },
    async (args, ctx) => {
      try {
        const input = parseToolInput(dailyAppendInput, args);
        return successResult(await dailyAppend(input, configuration.vaultPath, configuration.dailyPath, ctx.mcpReq.signal));
      } catch (error) {
        return errorResult(error);
      }
    },
  );
  server.registerResource(
    "taxonomy",
    "obsidian://taxonomy",
    { title: "Obsidian taxonomy", description: "Redacted vault taxonomy configuration.", mimeType: "text/plain" },
    async (uri, ctx) => readResource(uri, undefined, configuration, ctx.mcpReq.signal),
  );
  server.registerResource(
    "librarian",
    "obsidian://librarian",
    { title: "Obsidian librarian index", description: "The vault librarian index.", mimeType: "text/markdown" },
    async (uri, ctx) => readResource(uri, undefined, configuration, ctx.mcpReq.signal),
  );
  server.registerResource(
    "pending",
    "obsidian://pending",
    { title: "Obsidian pending items", description: "Pending vault workflow items.", mimeType: "text/markdown" },
    async (uri, ctx) => readResource(uri, undefined, configuration, ctx.mcpReq.signal),
  );
  server.registerResource(
    "daily",
    new ResourceTemplate("obsidian://daily/{date}", { list: undefined }),
    { title: "Obsidian daily note", description: "A bounded daily note.", mimeType: "text/markdown" },
    async (uri, variables, ctx) => readResource(uri, variables, configuration, ctx.mcpReq.signal),
  );
  return server;
}

export async function closeActiveChildren() {
  await Promise.all([...activeChildren].map((child) => terminateChild(child)));
}

export function startStdio() {
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
}

if (process.argv[1] && realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url))) startStdio();
