#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { constants as fsConstants, existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { lstat, open, readdir } from "node:fs/promises";
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

function codedError(code, detail, outcome) {
  const error = new Error(detail);
  error.code = code;
  if (outcome) error.outcome = outcome;
  return error;
}

function childEnvironment() {
  const allowed = [
    "PATH", "HOME", "XDG_CONFIG_HOME", "OBSIDIAN_LOCAL_MD", "CLAUDE_PLUGIN_ROOT", "LANG", "LC_ALL", "MCP_GIT_MARKER",
    "KEEPER_FAULT_INJECT", "KEEPER_FAULT_MODE", "KEEPER_TEST_PAUSE_POINT", "KEEPER_TEST_PAUSE_DIR",
  ];
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
  const configuredDailyPath = frontmatterValue(config, "daily_path");
  let dailyPath = "";
  let dailyPathError = "";
  if (!configuredDailyPath) {
    dailyPathError = "daily_path is missing from the Obsidian configuration";
  } else if (isAbsolute(configuredDailyPath)
    || configuredDailyPath.split(/[\\/]/).includes("..")
    || /[\r\n\t]/.test(configuredDailyPath)
    || !isContained(resolvedVault, resolve(resolvedVault, configuredDailyPath))) {
    dailyPathError = "daily_path must remain within the configured vault";
  } else {
    dailyPath = configuredDailyPath.replace(/^\/+|\/+$/g, "");
    if (!dailyPath) dailyPathError = "daily_path must identify a directory within the configured vault";
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
  return { config, configPath, dailyPath, dailyPathError, repositoryRoots, vaultPath: resolvedVault };
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

function emptyWriteOutcome(requestId, idempotencyKey, path, affectedPaths) {
  return {
    status: "failed",
    request_id: requestId,
    idempotency_key: idempotencyKey || "",
    path,
    affected_paths: affectedPaths,
    warnings: [],
    recovery: { required: false, action: "" },
    error_code: null,
    retryable: false,
  };
}

function failedWriteOutcome(fallback, errorCode, detail, parsed, recoverable = false) {
  if (parsed && ["partial", "conflict", "failed"].includes(parsed.status)) {
    return { ...parsed, warnings: [...parsed.warnings, detail] };
  }
  const recoveryRequired = recoverable || errorCode === "SUBPROCESS_TIMEOUT" || errorCode === "CANCELLED";
  return {
    ...fallback,
    status: recoverable ? "partial" : "failed",
    warnings: [...fallback.warnings, detail],
    recovery: {
      required: recoveryRequired,
      action: recoveryRequired
        ? "verify affected_paths, then retry with the same idempotency_key"
        : "",
    },
    error_code: errorCode,
    retryable: recoveryRequired,
  };
}

function writeRequestFallback(toolName, args, configuration) {
  const values = args && typeof args === "object" && !Array.isArray(args) ? args : {};
  const requestId = typeof values.request_id === "string" && /^[A-Za-z0-9._:-]{1,240}$/.test(values.request_id)
    ? values.request_id
    : randomUUID();
  const idempotencyKey = typeof values.idempotency_key === "string" && values.idempotency_key.length <= 240
    ? values.idempotency_key
    : "";
  if (toolName === "obsidian_keeper_save") {
    const title = typeof values.title === "string" ? values.title.trim().replace(/\.md$/i, "") : "";
    const folder = typeof values.folder_hint === "string" && values.folder_hint.trim()
      ? values.folder_hint.trim().replace(/^\/+|\/+$/g, "")
      : "Inbox";
    const path = title ? `${folder}/${title}.md` : "";
    return emptyWriteOutcome(requestId, idempotencyKey, path, path ? [path, `${folder}/INDEX.md`] : []);
  }
  const date = typeof values.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(values.date)
    ? values.date
    : new Date().toISOString().slice(0, 10);
  const path = configuration.dailyPath ? `${configuration.dailyPath}/${date}.md` : "";
  return emptyWriteOutcome(requestId, idempotencyKey, path, path ? [path] : []);
}

function requireWriteConfiguration(configuration) {
  if (configuration.dailyPathError) throw codedError("CONFIG_INVALID", configuration.dailyPathError);
}

function writeErrorResult(error, fallback) {
  if (error?.outcome) return errorResult(error);
  const adapterCodes = new Set([
    "INVALID_INPUT", "PATH_INVALID", "CONFIG_INVALID", "CONFLICT", "IDEMPOTENCY_CONFLICT",
    "PARTIAL", "WRITE_FAILED", "KEEPER_PROTOCOL_ERROR", "SUBPROCESS_TIMEOUT",
    "SUBPROCESS_OUTPUT_LIMIT", "CANCELLED",
  ]);
  const code = adapterCodes.has(error?.code) ? error.code : "WRITE_FAILED";
  const detail = error instanceof Error ? error.message : "write failed";
  return errorResult(codedError(code, detail, failedWriteOutcome(fallback, code, detail)));
}

function parseKeeperOutcome(stdout) {
  const text = stdout.trim();
  if (!text || text.split(/\r?\n/).length !== 1) throw codedError("KEEPER_PROTOCOL_ERROR", "keeper returned zero or multiple structured results");
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw codedError("KEEPER_PROTOCOL_ERROR", "keeper returned malformed structured output");
  }
  const result = writeOutput.safeParse(parsed);
  if (!result.success) throw codedError("KEEPER_PROTOCOL_ERROR", "keeper returned an invalid structured result");
  if (result.data.path && (isAbsolute(result.data.path) || result.data.path.split("/").includes(".."))) {
    throw codedError("KEEPER_PROTOCOL_ERROR", "keeper returned an invalid primary path");
  }
  for (const path of result.data.affected_paths) {
    if (isAbsolute(path) || path.split("/").includes("..")) throw codedError("KEEPER_PROTOCOL_ERROR", "keeper returned an invalid affected path");
  }
  return result.data;
}

function compatibleKeeperExit(code, outcome) {
  return (code === 0 && ["committed", "skipped"].includes(outcome.status))
    || (code === 1 && outcome.status === "failed")
    || (code === 2 && outcome.status === "partial")
    || (code === 3 && outcome.status === "conflict");
}

async function executeKeeperWrite(args, bodyContent, signal, fallback) {
  throwIfAborted(signal);
  const fullArgs = [...args, "--format", "json"];
  return await new Promise((resolveResult, reject) => {
      const child = spawn("bash", [keeperScript, ...fullArgs], {
        env: childEnvironment(),
        detached: process.platform !== "win32",
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
      activeChildren.add(child);
      let stdout = "";
      let stderrOutput = "";
      let settled = false;
      let stopping = false;
      let stopError;
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
        stopError = codedError("CANCELLED", "request cancelled");
        void terminateChild(child);
      };
      const stop = (error) => {
        if (settled || stopping) return;
        stopping = true;
        stopError = error;
        void terminateChild(child);
      };
      if (signal) {
        signal.addEventListener("abort", onAbort, { once: true });
        if (signal.aborted) onAbort();
      }
      timer = setTimeout(() => stop(codedError("SUBPROCESS_TIMEOUT", "keeper write timed out")), subprocessTimeoutMs);
      child.stdin.on("error", () => {});
      child.stdin.end(bodyContent);
      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
        if (Buffer.byteLength(stdout, "utf8") > maxChildOutput) stop(codedError("SUBPROCESS_OUTPUT_LIMIT", "keeper exceeded output limit"));
      });
      child.stderr.on("data", (chunk) => {
        stderrOutput += chunk.toString();
        if (Buffer.byteLength(stderrOutput, "utf8") > maxChildOutput) stop(codedError("SUBPROCESS_OUTPUT_LIMIT", "keeper exceeded output limit"));
      });
      child.on("error", (error) => {
        if (!stopping) {
          const recoverable = Boolean(fallback.idempotency_key);
          const errorCode = recoverable ? "KEEPER_PROTOCOL_ERROR" : "WRITE_FAILED";
          const detail = recoverable ? "keeper result was missing or invalid" : "keeper process failed";
          const outcome = failedWriteOutcome(fallback, errorCode, detail, undefined, recoverable);
          finish(reject, codedError(errorCode, recoverable ? detail : error.message, outcome));
        }
      });
      child.on("close", (code) => {
        let parsed;
        try {
          parsed = parseKeeperOutcome(stdout);
        } catch {}
        if (stopping) {
          const errorCode = stopError?.code || "WRITE_FAILED";
          const detail = errorCode === "CANCELLED" ? "request cancelled" : "keeper write timed out";
          const outcome = failedWriteOutcome(fallback, errorCode, detail, parsed);
          finish(reject, codedError(errorCode, detail, outcome));
          return;
        }
        if (!parsed) {
          const recoverable = Boolean(fallback.idempotency_key);
          const outcome = failedWriteOutcome(fallback, "KEEPER_PROTOCOL_ERROR", "keeper result was missing or invalid", undefined, recoverable);
          finish(reject, codedError("KEEPER_PROTOCOL_ERROR", "keeper result was missing or invalid", outcome));
          return;
        }
        if (parsed.request_id !== fallback.request_id || parsed.idempotency_key !== fallback.idempotency_key) {
          const recoverable = Boolean(fallback.idempotency_key);
          const outcome = failedWriteOutcome(fallback, "KEEPER_PROTOCOL_ERROR", "keeper result did not match the request identity", undefined, recoverable);
          finish(reject, codedError("KEEPER_PROTOCOL_ERROR", "keeper result did not match the request identity", outcome));
          return;
        }
        if (!compatibleKeeperExit(code, parsed)) {
          const recoverable = Boolean(fallback.idempotency_key);
          const outcome = failedWriteOutcome(fallback, "KEEPER_PROTOCOL_ERROR", "keeper result contradicted its exit status", undefined, recoverable);
          finish(reject, codedError("KEEPER_PROTOCOL_ERROR", "keeper result contradicted its exit status", outcome));
          return;
        }
        if (parsed.status === "committed" || parsed.status === "skipped") {
          finish(resolveResult, parsed);
          return;
        }
        finish(reject, codedError(parsed.error_code || "WRITE_FAILED", stderrOutput.trim() || parsed.status, parsed));
      });
    });
}

async function keeperSave({ title, body, folder_hint, type, links, idempotency_key, request_id }, vaultPath, signal) {
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

  const requestId = request_id || randomUUID();
  const idempotencyKey = idempotency_key || "";
  const fallback = emptyWriteOutcome(requestId, idempotencyKey, targetPath, [targetPath, `${targetFolder}/INDEX.md`]);
  return executeKeeperWrite(
    ["insert", "--vault", vaultPath, "--target", targetPath, "--title", cleanTitle, "--request-id", requestId, "--idempotency-key", idempotencyKey],
    formattedBody,
    signal,
    fallback,
  );
}

async function dailyAppend({ content, section, date, skip_if_hash, idempotency_key, request_id }, vaultPath, dailyPath, signal) {
  const targetDate = date || new Date().toISOString().slice(0, 10);
  const targetPath = `${dailyPath.replace(/\/+$/, "")}/${targetDate}.md`;
  const requestId = request_id || randomUUID();
  const idempotencyKey = idempotency_key || "";
  const args = ["append", "--vault", vaultPath, "--target", targetPath, "--request-id", requestId, "--idempotency-key", idempotencyKey];
  if (section) args.push("--section", section);
  if (skip_if_hash) args.push("--skip-if-hash", skip_if_hash);
  return executeKeeperWrite(args, content, signal, emptyWriteOutcome(requestId, idempotencyKey, targetPath, [targetPath]));
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
    "CANCELLED", "FORBIDDEN", "CONFIG_INVALID", "CONFLICT", "IDEMPOTENCY_CONFLICT", "PARTIAL", "WRITE_FAILED", "KEEPER_PROTOCOL_ERROR"
  ]);
  const code = knownCodes.has(error?.code) ? error.code : "READ_FAILED";
  const detail = {
    INVALID_INPUT: "invalid tool input",
    PATH_INVALID: "requested path is not allowed",
    CONFIG_INVALID: "Obsidian configuration is invalid",
    FORBIDDEN: "insufficient scope",
    CONFLICT: "write conflict",
    IDEMPOTENCY_CONFLICT: "idempotency key conflicts with an earlier payload",
    PARTIAL: "partial write occurred",
    WRITE_FAILED: "write failed",
    KEEPER_PROTOCOL_ERROR: "keeper result contract failed",
    READ_FAILED: "read failed",
    SCAN_LIMIT: "vault scan limit exceeded",
    METADATA_INCOMPLETE: "commit metadata was incomplete",
    SUBPROCESS_TIMEOUT: "subprocess timed out",
    SUBPROCESS_OUTPUT_LIMIT: "output limit exceeded",
    CANCELLED: "request cancelled",
  }[code];
  const payload = error?.outcome ? { code, detail, ...error.outcome } : { code, detail };
  return { content: [{ type: "text", text: JSON.stringify(payload) }], isError: true, ...(error?.outcome ? { structuredContent: error.outcome } : {}) };
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
  request_id: z.string().min(1).max(240),
  idempotency_key: z.string().max(240),
  path: z.string(),
  affected_paths: z.array(z.string()),
  warnings: z.array(z.string()),
  recovery: z.strictObject({ required: z.boolean(), action: z.string() }),
  error_code: z.string().nullable(),
  retryable: z.boolean(),
}).superRefine((value, context) => {
  const successful = ["committed", "skipped"].includes(value.status);
  const pathsAreComplete = value.path.length > 0
    && value.affected_paths.length > 0
    && value.affected_paths.every((path) => path.length > 0);
  if (successful && (value.error_code !== null || value.recovery.required || value.retryable || !pathsAreComplete)) {
    context.addIssue({ code: "custom", message: "successful keeper outcomes contain contradictory state" });
  }
  if (successful && value.recovery.action !== "") {
    context.addIssue({ code: "custom", message: "successful keeper outcomes cannot carry a recovery action" });
  }
  if (!successful && (value.error_code === null || value.error_code.length === 0)) {
    context.addIssue({ code: "custom", message: "failed keeper outcomes require an error code" });
  }
  if (value.status === "partial" && (!pathsAreComplete || !value.recovery.required || !value.retryable || value.recovery.action.length === 0)) {
    context.addIssue({ code: "custom", message: "partial keeper outcomes require paths and recovery instructions" });
  }
  if (value.status === "conflict" && (value.recovery.required || value.retryable || value.recovery.action !== "")) {
    context.addIssue({ code: "custom", message: "conflict keeper outcomes cannot request recovery" });
  }
  if (value.status === "failed" && (value.recovery.required !== value.retryable || value.recovery.required !== (value.recovery.action.length > 0))) {
    context.addIssue({ code: "custom", message: "failed keeper outcome recovery fields disagree" });
  }
});

const searchInput = z.strictObject({ query: z.string().trim().min(1).max(240) });
const metadataInput = z.strictObject({ repository: z.string().trim().min(1).max(maxRepositoryPathCharacters) });
const keeperSaveInput = z.strictObject({
  title: z.string().trim().min(1).max(240),
  body: z.string().min(1).max(65536),
  folder_hint: z.string().max(1024).optional(),
  type: z.string().max(100).optional(),
  links: z.array(z.string()).max(20).optional(),
  idempotency_key: z.string().min(1).max(240).regex(/^[A-Za-z0-9._:-]+$/).optional(),
  request_id: z.string().min(1).max(240).regex(/^[A-Za-z0-9._:-]+$/).optional(),
});

const dailyAppendInput = z.strictObject({
  content: z.string().min(1).max(65536),
  section: z.string().max(240).optional(),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  skip_if_hash: z.string().regex(/^[0-9a-fA-F]+$/).optional(),
  idempotency_key: z.string().min(1).max(240).regex(/^[A-Za-z0-9._:-]+$/).optional(),
  request_id: z.string().min(1).max(240).regex(/^[A-Za-z0-9._:-]+$/).optional(),
});

export function createServer({ supportedProtocolVersions = protocolVersions, scopes = ["vault:read", "repo:read", "vault:write"], requireWriteIdempotency = false } = {}) {
  const configuration = loadConfiguration();
  const availableScopes = new Set(scopes);
  const server = new McpServer(
    { name: "claude-obsidian-mcp", version: "0.1.0" },
    { capabilities: { tools: {}, resources: { listChanged: false }, prompts: { listChanged: false } }, supportedProtocolVersions },
  );
  server.registerPrompt(
    "obsidian_ask",
    {
      title: "Ask Vault Librarian",
      description: "System instructions and context for index-grounded vault querying with citations and confidence reporting.",
      argsSchema: { query: z.string().optional() },
    },
    async ({ query } = {}) => ({
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: `You are the vault librarian for the Obsidian vault.
Your goal is to answer queries with index-grounded evidence from notes, cite using [[note]] wikilinks, state confidence (high/medium/low), and report any coverage gaps.

Query: ${query || "What is stored in the vault?"}`,
          },
        },
      ],
    }),
  );
  server.registerPrompt(
    "summarize_session",
    {
      title: "Summarize Session to Vault",
      description: "Prompt template for session-end intent inference, decision extraction, and note filing.",
      argsSchema: { topic_hint: z.string().optional() },
    },
    async ({ topic_hint } = {}) => ({
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: `Evaluate the current session transcript. Infer the session intent (execution, research, planning, reflection), extract key decisions, goals, and open threads, and construct a structured note payload.
${topic_hint ? `Topic Hint: ${topic_hint}` : ""}`,
          },
        },
      ],
    }),
  );
  server.registerPrompt(
    "reorganize_vault",
    {
      title: "Reorganize Vault Structure",
      description: "Prompt template for vault structure analysis, MOC promotion, and proposed reorg plans requiring user approval.",
      argsSchema: { folder: z.string().optional() },
    },
    async ({ folder } = {}) => ({
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: `Analyze the folder structure and note clusters ${folder ? `in ${folder}` : "across the vault"}. Identify notes eligible for Map of Content (MOC) promotion or reorganization, and output a proposed plan for user approval before moving any files.`,
          },
        },
      ],
    }),
  );
  if (availableScopes.has("vault:read")) server.registerTool(
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
  if (availableScopes.has("repo:read")) server.registerTool(
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
  if (availableScopes.has("vault:write")) server.registerTool(
    "obsidian_keeper_save",
    {
      title: "Save Obsidian note",
      description: "Save a structured note to the Obsidian vault.",
      inputSchema: z.unknown(),
      outputSchema: writeOutput,
    },
    async (args, ctx) => {
      const fallback = writeRequestFallback("obsidian_keeper_save", args, configuration);
      try {
        requireWriteConfiguration(configuration);
        const input = parseToolInput(keeperSaveInput, args);
        if (requireWriteIdempotency && !input.idempotency_key) throw codedError("INVALID_INPUT", "idempotency_key is required for remote writes");
        return successResult(await keeperSave({ ...input, request_id: input.request_id || fallback.request_id }, configuration.vaultPath, ctx.mcpReq.signal));
      } catch (error) {
        return writeErrorResult(error, fallback);
      }
    },
  );
  if (availableScopes.has("vault:write")) server.registerTool(
    "obsidian_daily_append",
    {
      title: "Append to daily note",
      description: "Append a section to today's daily note in the Obsidian vault.",
      inputSchema: z.unknown(),
      outputSchema: writeOutput,
    },
    async (args, ctx) => {
      const fallback = writeRequestFallback("obsidian_daily_append", args, configuration);
      try {
        requireWriteConfiguration(configuration);
        const input = parseToolInput(dailyAppendInput, args);
        if (requireWriteIdempotency && !input.idempotency_key) throw codedError("INVALID_INPUT", "idempotency_key is required for remote writes");
        return successResult(await dailyAppend({ ...input, request_id: input.request_id || fallback.request_id }, configuration.vaultPath, configuration.dailyPath, ctx.mcpReq.signal));
      } catch (error) {
        return writeErrorResult(error, fallback);
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
