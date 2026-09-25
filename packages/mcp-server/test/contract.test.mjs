import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const contract = JSON.parse(await readFile(new URL("../contract.json", import.meta.url), "utf8"));
const fixtures = JSON.parse(await readFile(new URL("./fixtures/contract-fixtures.json", import.meta.url), "utf8"));

test("pins the MCP protocol and transport boundary", () => {
  assert.equal(contract.protocol.sdk, "@modelcontextprotocol/server@2.0.0");
  assert.equal(contract.protocol.modernRevision, "2026-07-28");
  assert.deepEqual(contract.protocol.compatibilityRevisions, ["2025-11-25"]);
  assert.deepEqual(contract.protocol.transports.mvp, ["stdio", "streamable-http"]);
  assert.deepEqual(contract.protocol.transports.planned, []);
  assert.deepEqual(contract.protocol.transports.compatibilityOnly, ["http+sse"]);
  assert.deepEqual(contract.scopes.streamableHttp, ["vault:read", "repo:read", "vault:write"]);
  assert.deepEqual(contract.protocol.clientMatrix, [
    { protocolRevision: "2026-07-28", transport: "stdio", status: "supported" },
    { protocolRevision: "2025-11-25", transport: "stdio", status: "compatibility" },
    { protocolRevision: "2026-07-28", transport: "streamable-http", status: "planned" },
    { protocolRevision: "2025-11-25", transport: "streamable-http", status: "compatibility" },
  ]);
  assert.equal(contract.http.defaultBind, "127.0.0.1");
  assert.equal(contract.http.authentication, "HS256 bearer JWT on every request");
  assert.equal(contract.http.queryCredentials, false);
  assert.deepEqual(fixtures.initialize, {
    modern: "2026-07-28",
    compatibility: "2025-11-25",
    transport: "stdio"
  });
});

test("pins tool surface including write tools", () => {
  assert.deepEqual(Object.keys(contract.tools), [
    "obsidian_find_notes",
    "obsidian_commit_meta",
    "obsidian_keeper_save",
    "obsidian_daily_append"
  ]);
  assert.equal(contract.tools.obsidian_find_notes.readOnly, true);
  assert.equal(contract.tools.obsidian_commit_meta.readOnly, true);
  assert.equal(contract.tools.obsidian_keeper_save.readOnly, false);
  assert.equal(contract.tools.obsidian_daily_append.readOnly, false);
  assert.equal(contract.tools.obsidian_find_notes.scope, "vault:read");
  assert.equal(contract.tools.obsidian_commit_meta.scope, "repo:read");
  assert.equal(contract.tools.obsidian_keeper_save.scope, "vault:write");
  assert.equal(contract.tools.obsidian_daily_append.scope, "vault:write");
  assert.ok(!contract.tools.obsidian_keeper_save.inputSchema.required.includes("idempotency_key"));
  assert.ok(!contract.tools.obsidian_daily_append.inputSchema.required.includes("idempotency_key"));
  assert.match(contract.tools.obsidian_keeper_save.idempotency, /required for Streamable HTTP writes/);
  assert.match(contract.tools.obsidian_daily_append.idempotency, /optional for local stdio compatibility/);
  assert.deepEqual(contract.tools.obsidian_keeper_save.resultSchema.required, [
    "status", "request_id", "idempotency_key", "path", "affected_paths", "warnings", "recovery", "error_code", "retryable"
  ]);
  assert.deepEqual(contract.tools.obsidian_daily_append.resultSchema.required, contract.tools.obsidian_keeper_save.resultSchema.required);
  assert.ok(contract.tools.obsidian_keeper_save.errors.includes("KEEPER_PROTOCOL_ERROR"));
  assert.ok(contract.tools.obsidian_keeper_save.errors.includes("SUBPROCESS_OUTPUT_LIMIT"));
  assert.ok(contract.tools.obsidian_daily_append.errors.includes("CONFIG_INVALID"));
  assert.equal(contract.tools.obsidian_daily_append.inputSchema.properties.skip_if_hash.minLength, 7);
  assert.deepEqual(fixtures.toolCalls.map(({ name }) => name), Object.keys(contract.tools));
});

test("pins read prompts and keeps admin prompts and writes gated", () => {
  assert.deepEqual(contract.protocol.transports.compatibilityOnly, ["http+sse"]);
  assert.deepEqual(contract.protocol.transports.planned, []);
  assert.ok(Object.values(contract.resources).every((resource) => resource.status === "mvp"));
  assert.deepEqual(
    fixtures.resources.map(({ uri }) => uri),
    ["obsidian://taxonomy", "obsidian://daily/2026-09-20", "obsidian://librarian", "obsidian://pending"],
  );
  assert.deepEqual(Object.keys(contract.prompts), ["ask_vault_librarian", "summarize_session", "reorganize_vault"]);
  assert.equal(contract.prompts.ask_vault_librarian.status, "mvp");
  assert.equal(contract.prompts.ask_vault_librarian.serverModel, false);
  assert.equal(contract.prompts.ask_vault_librarian.scope, "vault:read");
  assert.equal(contract.prompts.summarize_session.status, "mvp");
  assert.equal(contract.prompts.summarize_session.scope, "vault:read");
  assert.equal(contract.prompts.reorganize_vault.status, "excluded-from-mcp-mvp");
  assert.equal(contract.prompts.reorganize_vault.scope, "vault:admin");
  assert.equal(contract.writes.mvp, false);
  assert.deepEqual(contract.writes.statuses, fixtures.writeStatuses);
  assert.ok(fixtures.errors.every(({ isError }) => isError === true));
  assert.ok(contract.cancellation.handlerSignal.includes("mcpReq.signal"));
  assert.ok(contract.tools.obsidian_commit_meta.errors.includes("PATH_INVALID"));
  assert.equal(contract.tools.obsidian_commit_meta.resultSchema.properties.repositoryPath, undefined);
  assert.equal(contract.limits.maxScanEntries, 10000);
  assert.deepEqual(contract.errors.schema.required, ["code", "detail"]);
});

test("adapter contains no direct filesystem mutation path", async () => {
  const source = `${await readFile(new URL("../src/stdio.mjs", import.meta.url), "utf8")}\n${await readFile(new URL("../src/http.mjs", import.meta.url), "utf8")}`;
  assert.doesNotMatch(source, /\b(?:writeFile|writeFileSync|appendFile|appendFileSync|rename|renameSync|rm|rmSync|unlink|unlinkSync|mkdir|mkdirSync|mkdtemp|mkdtempSync)\b/);
  assert.match(source, /spawn\("bash", \[keeperScript/);
});
