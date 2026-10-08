import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import { keeperDiagnostics, keeperProgress, keeperSave, noteWrittenStopOutcome, writeOutput } from "../src/stdio.mjs";

const packageRoot = resolve(dirname(new URL(import.meta.url).pathname), "..");

const keyed = Object.freeze({
  status: "failed",
  request_id: "req-1",
  idempotency_key: "key-1",
  path: "Inbox/Note.md",
  affected_paths: ["Inbox/Note.md", "Inbox/INDEX.md"],
  warnings: [],
  recovery: { required: false, action: "" },
  error_code: null,
  retryable: false,
});
const keyless = Object.freeze({ ...keyed, idempotency_key: "" });

function assertContract(outcome) {
  const result = writeOutput.safeParse(outcome);
  assert.ok(result.success, `${JSON.stringify(result.error?.issues)} ${JSON.stringify(outcome)}`);
}

test("subprocess caps default to 25 s for keeper saves, 10 s for daily appends, 5 s for commit metadata", { timeout: 30_000 }, () => {
  // A clean environment: none of the cap settings inherited from the runner.
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/_TIMEOUT_MS$/.test(key)));
  const result = spawnSync(process.execPath, ["--input-type=module", "-e",
    `const m = await import(${JSON.stringify(pathToFileURL(join(packageRoot, "src", "stdio.mjs")).href)});
     process.stdout.write(JSON.stringify(m.subprocessTimeouts));`], { env, encoding: "utf8", timeout: 20_000 });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { commitMeta: 5_000, keeperSave: 25_000, dailyAppend: 10_000 });
});

test("progress parser accepts only this run's token and the pinned events", { timeout: 10_000 }, () => {
  const stderr = [
    "keeper-progress other: index-written",                  // another run's token
    "keeper-progress: note-written pending=index",           // untagged
    "vault_index_plan: skipping TSV-incompatible filename: x\\nkeeper-progress tok: index-written",
    "keeper-progress tok: note-written pending=index,future-step,idempotency",
    "keeper-progress tok: index-written trailing",           // not an exact event
    "keeper-progress tok: future-step-written",              // unknown event: ignored
  ].join("\n");
  assert.deepEqual(keeperProgress(stderr, "tok"), {
    noteWritten: true,
    unfinished: ["INDEX", "future-step", "idempotency record (retry with the same idempotency_key)"],
  });
  assert.deepEqual(keeperProgress(`${stderr}\nkeeper-progress tok: index-written\nkeeper-progress tok: idempotency-written`, "tok"),
    { noteWritten: true, unfinished: ["future-step"] });
  assert.deepEqual(keeperProgress("keeper-progress tok: index-written", "tok"), { noteWritten: false, unfinished: [] });
});

test("keeper diagnostics drop progress markers and keep everything else", { timeout: 10_000 }, () => {
  const stderr = "keeper: partial — Inbox/Note.md was written\nkeeper-progress tok: note-written pending=index\nkeeper-progress tok: index-written\nkeeper: detail";
  assert.equal(keeperDiagnostics(stderr), "keeper: partial — Inbox/Note.md was written\nkeeper: detail");
  assert.doesNotMatch(keeperDiagnostics(stderr), /keeper-progress/);
});

test("a keeper save with session_link_date reports the daily link as unfinished after a stop", () => {
  const stderr = "keeper-progress tok: note-written pending=index,daily-link\nkeeper-progress tok: index-written";
  assert.deepEqual(keeperProgress(stderr, "tok"), { noteWritten: true, unfinished: ["daily Session Link"] });
  const stopped = noteWrittenStopOutcome(keyed, "SUBPROCESS_TIMEOUT", ["daily Session Link"], "MCP_KEEPER_SAVE_TIMEOUT_MS");
  assertContract(stopped);
  assert.match(stopped.recovery.action, /daily Session Link/);
});

test("a stop after the note is written is worded by its cause and keeps the write contract", { timeout: 10_000 }, () => {
  const timeout = noteWrittenStopOutcome(keyed, "SUBPROCESS_TIMEOUT", ["INDEX"], "MCP_KEEPER_SAVE_TIMEOUT_MS");
  assertContract(timeout);
  assert.equal(timeout.status, "partial");
  assert.equal(timeout.retryable, true);
  assert.equal(timeout.recovery.action, "do not rewrite the note; raise MCP_KEEPER_SAVE_TIMEOUT_MS, then retry with the same idempotency_key to finish INDEX");
  assert.ok(timeout.warnings.includes("raise MCP_KEEPER_SAVE_TIMEOUT_MS before retrying; the same cap would stop the retry at the same step"));

  const cancelled = noteWrittenStopOutcome(keyed, "CANCELLED", ["INDEX"], "MCP_KEEPER_SAVE_TIMEOUT_MS");
  assertContract(cancelled);
  assert.equal(cancelled.retryable, true);
  assert.equal(cancelled.recovery.action, "do not rewrite the note; retry with the same idempotency_key to finish INDEX");
  assert.deepEqual(cancelled.warnings, ["keeper write was cancelled after the note was written to Inbox/Note.md; unfinished: INDEX"]);
  assert.doesNotMatch(JSON.stringify(cancelled), /raise|more time|MCP_KEEPER_SAVE_TIMEOUT_MS/);

  const limited = noteWrittenStopOutcome(keyed, "SUBPROCESS_OUTPUT_LIMIT", [], "MCP_KEEPER_SAVE_TIMEOUT_MS");
  assertContract(limited);
  assert.equal(limited.recovery.action, "do not rewrite the note; retry with the same idempotency_key to confirm the write");
  assert.deepEqual(limited.warnings, ["keeper write exceeded its output limit after the note was written to Inbox/Note.md; nothing known unfinished"]);

  const exited = noteWrittenStopOutcome(keyless, "KEEPER_PROTOCOL_ERROR", ["INDEX"], "MCP_KEEPER_SAVE_TIMEOUT_MS");
  assertContract(exited);
  assert.equal(exited.status, "failed");
  assert.equal(exited.retryable, false);
  assert.equal(exited.recovery.action, "do not rewrite the note; finish INDEX for Inbox/Note.md manually");
  assert.equal(exited.warnings[0], "keeper write exited without a result after the note was written to Inbox/Note.md; unfinished: INDEX");
});

test("a keeper that fails after writing the note reports its diagnostics without progress markers", { timeout: 30_000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), "mcp-keeper-detail-"));
  const vault = join(root, "vault");
  await mkdir(join(vault, "Inbox"), { recursive: true });
  // The real keeper: the fault prints its own diagnostic, after the
  // note-written marker, and the keeper exits with a partial outcome.
  process.env.KEEPER_FAULT_INJECT = "after_note";
  t.after(async () => {
    delete process.env.KEEPER_FAULT_INJECT;
    await rm(root, { recursive: true, force: true });
  });
  const error = await keeperSave({ title: "Detail", body: "Detail body", folder_hint: "Inbox", idempotency_key: "detail-1", request_id: "detail" }, vault)
    .then(() => assert.fail("keeper save succeeded despite the injected fault"), (rejection) => rejection);
  assert.equal(error.outcome?.status, "partial", error.message);
  assert.match(error.message, /injected fault at after_note/);
  assert.doesNotMatch(error.message, /keeper-progress/);
});
