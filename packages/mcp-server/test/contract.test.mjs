import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const contract = JSON.parse(await readFile(new URL("../contract.json", import.meta.url), "utf8"));
const fixtures = JSON.parse(await readFile(new URL("./fixtures/contract-fixtures.json", import.meta.url), "utf8"));

test("pins the MCP protocol and transport boundary", () => {
  assert.equal(contract.protocol.sdk, "@modelcontextprotocol/server@2.0.0");
  assert.equal(contract.protocol.modernRevision, "2026-07-28");
  assert.deepEqual(contract.protocol.compatibilityRevisions, ["2025-11-25"]);
  assert.deepEqual(contract.protocol.transports.mvp, ["stdio"]);
  assert.deepEqual(contract.protocol.transports.planned, ["streamable-http"]);
  assert.deepEqual(contract.protocol.transports.compatibilityOnly, ["http+sse"]);
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
    assert.equal(tool.scope, "vault:read");
    assert.equal(tool.idempotency, "not-required-read-only");
  }
  assert.deepEqual(fixtures.toolCalls.map(({ name }) => name), Object.keys(contract.tools));
});

test("keeps future resources, prompts, and writes gated", () => {
  assert.ok(Object.values(contract.resources).every((resource) => resource.status === "planned-read-only"));
  assert.equal(contract.prompts.obsidian_ask.serverModel, false);
  assert.equal(contract.prompts.reorganize_vault.status, "excluded-from-mcp-mvp");
  assert.equal(contract.writes.mvp, false);
  assert.deepEqual(contract.writes.statuses, fixtures.writeStatuses);
  assert.ok(fixtures.errors.every(({ isError }) => isError === true));
});
