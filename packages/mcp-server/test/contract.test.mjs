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
  assert.deepEqual(contract.scopes.streamableHttp, ["vault:read", "repo:read"]);
  assert.equal(contract.http.defaultBind, "127.0.0.1");
  assert.equal(contract.http.authentication, "HS256 bearer JWT on every request");
  assert.equal(contract.http.queryCredentials, false);
  assert.deepEqual(fixtures.initialize, {
    modern: "2026-07-28",
    compatibility: "2025-11-25",
    transport: "stdio"
  });
});

test("pins the initial read-only tool surface", () => {
  assert.deepEqual(Object.keys(contract.tools), ["obsidian_find_notes", "obsidian_commit_meta"]);
  for (const tool of Object.values(contract.tools)) {
    assert.equal(tool.status, "mvp");
    assert.equal(tool.readOnly, true);
    assert.equal(tool.idempotency, "not-required-read-only");
  }
  assert.equal(contract.tools.obsidian_find_notes.scope, "vault:read");
  assert.equal(contract.tools.obsidian_commit_meta.scope, "repo:read");
  assert.deepEqual(fixtures.toolCalls.map(({ name }) => name), Object.keys(contract.tools));
});

test("keeps future resources, prompts, and writes gated", () => {
  assert.ok(Object.values(contract.resources).every((resource) => resource.status === "mvp"));
  assert.deepEqual(
    fixtures.resources.map(({ uri }) => uri),
    ["obsidian://taxonomy", "obsidian://daily/2026-09-20", "obsidian://librarian", "obsidian://pending"],
  );
  assert.equal(contract.prompts.obsidian_ask.serverModel, false);
  assert.equal(contract.prompts.reorganize_vault.status, "mvp");
  assert.equal(contract.writes.mvp, false);
  assert.deepEqual(contract.writes.statuses, fixtures.writeStatuses);
  assert.ok(fixtures.errors.every(({ isError }) => isError === true));
  assert.ok(contract.cancellation.handlerSignal.includes("mcpReq.signal"));
  assert.ok(contract.tools.obsidian_commit_meta.errors.includes("PATH_INVALID"));
  assert.equal(contract.tools.obsidian_commit_meta.resultSchema.properties.repositoryPath, undefined);
  assert.equal(contract.limits.maxScanEntries, 10000);
  assert.deepEqual(contract.errors.schema.required, ["code", "detail"]);
});
