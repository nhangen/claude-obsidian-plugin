#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
python3 - <<'TESTS'
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ["ROOT_DIR"])
MODEL = "claude-haiku-5-5"
COUNTERS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
ALIASES = ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")
NOTE = """---
vault_folder: Inbox/
slug: fixture-summary
session_intent: execution
capture_action: project_note
research_state_change: none
---
# Fixture Summary
Offline note fixture.
"""


class SummaryUsage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.vault = self.base / "vault"
        self.vault.mkdir()
        self.config = self.base / "config.md"
        self.configure()
        stub = self.bin / "claude"
        stub.write_text("""#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
base = Path(os.environ['FIXTURE_BASE'])
with (base / 'calls').open('a') as stream:
    stream.write(json.dumps({'args':sys.argv[1:], 'effort':os.environ.get('CLAUDE_CODE_EFFORT_LEVEL'), 'guard':os.environ.get('OBSIDIAN_SUMMARIZING')})+'\\n')
sys.stdin.read()
sys.stderr.write('SECRET PROVIDER ERROR')
sys.stdout.write((base / 'response').read_text())
sys.exit(int(os.environ.get('FIXTURE_EXIT','0')))
""")
        stub.chmod(0o700)
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "HOME": str(self.base), "XDG_STATE_HOME": str(self.base / "state"),
                    "XDG_CACHE_HOME": str(self.base / "cache"), "TMPDIR": str(self.base),
                    "FIXTURE_BASE": str(self.base), "ANTHROPIC_API_KEY": "",
                    "CLAUDE_CODE_EFFORT_LEVEL": "max", "CLAUDE_CODE_USE_BEDROCK": "",
                    "CLAUDE_CODE_USE_VERTEX": "", "CLAUDE_CODE_USE_FOUNDRY": ""}

    def configure(self, extra=""):
        self.config.write_text("---\nvault_path: " + str(self.vault) + "\ndaily_path: Daily/\n" + extra + "---\n\n## Project Taxonomy\n\n| Domain | Vault path |\n|---|---|\n| Inbox | Inbox/ |\n| Daily | Daily/ |\n")

    def invoke(self, payload=None, raw=None, exit_code=0, source="private/source/session"):
        transcript = self.base / "transcript"
        transcript.write_text('RAW TRANSCRIPT SECRET')
        if payload is None:
            payload = {"type": "result", "subtype": "success", "is_error": False, "result": "SKIP"}
        (self.base / "response").write_text(raw if raw is not None else json.dumps(payload))
        before = set((self.base / "state/obsidian/summary-usage").glob("*.json"))
        result = subprocess.run(["bash", str(ROOT / "scripts/session-summarize.sh"),
                                 str(transcript), str(self.config), str(self.vault), source],
                                env={**self.env, "FIXTURE_EXIT": str(exit_code)}, capture_output=True, text=True)
        records = set((self.base / "state/obsidian/summary-usage").glob("*.json")) - before
        self.assertEqual(len(records), 1, result.stderr)
        path = records.pop()
        record = json.loads(path.read_text())
        self.assertFalse(transcript.exists())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        for secret in ("RAW TRANSCRIPT SECRET", "SECRET PROVIDER ERROR", "private/source/session", NOTE):
            self.assertNotIn(secret, path.read_text())
        self.assertNotIn("SECRET PROVIDER ERROR", result.stderr)
        return result, record

    def calls(self):
        return [json.loads(line) for line in (self.base / "calls").read_text().splitlines()]

    def test_explicit_default_and_both_auth_routes(self):
        for key in ("", "fixture-key"):
            self.env["ANTHROPIC_API_KEY"] = key
            result, record = self.invoke()
            self.assertEqual(result.returncode, 0, result.stderr)
            call = self.calls()[-1]
            args = call["args"]
            for flag, value in (("--model", MODEL), ("--effort", "low"), ("--output-format", "json"), ("--setting-sources", "")):
                self.assertEqual(args[args.index(flag)+1], value)
            settings = json.loads(args[args.index("--settings")+1])
            self.assertEqual(settings, {"availableModels": [MODEL], "enforceAvailableModels": True, "fallbackModel": []})
            self.assertEqual(call["effort"], "low")
            self.assertEqual(call["guard"], "1")
            self.assertEqual("--bare" in args, bool(key))
            self.assertNotIn("--no-session-persistence", args)
            self.assertEqual(record["auth_category"], "api_key" if key else "cli_login_or_unknown")
            self.assertEqual(record["requested_model"], MODEL)
            self.assertEqual(record["attempts"], 1)
            self.assertEqual(record["successful_calls"], 1)
            self.assertEqual(record["usage_status"], "missing")
            self.assertEqual(record["usage"], dict.fromkeys(COUNTERS))
            self.assertEqual(record["dedup_outcome"], "skipped")
            self.assertEqual(len(record["source_session_hash"]), 64)
            self.assertEqual(len(record["source_boundary_sha256"]), 64)

    def test_quoted_override_and_unknown_config_fail_before_call(self):
        self.configure('summary_model: "claude-sonnet-5-5" # explicit override\nsummary_effort: high\n')
        result, record = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(record["requested_model"], "claude-sonnet-5-5")
        self.assertEqual(self.calls()[-1]["effort"], "high")
        count = len(self.calls())
        for extra in ('summary_model: expensive-typo\n', 'summary_model: ""\n', 'summary_effort: typo\n', 'summary_effort: ""\n'):
            self.configure(extra)
            result, record = self.invoke()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(record["attempts"], 0)
            self.assertEqual(record["completion"], "error")
            self.assertIn("set summary_", result.stderr)
        self.assertEqual(len(self.calls()), count)

    def test_per_model_usage_precedes_aggregate_and_preserves_zero(self):
        payload = {"type":"result", "subtype":"success", "is_error":False, "result":"SKIP",
                   "modelUsage": {MODEL:dict(zip(ALIASES, (12, 3, 0, 5)))},
                   "usage":dict.fromkeys(COUNTERS, 999)}
        result, record = self.invoke(payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(record["actual_models"], [MODEL])
        self.assertEqual(record["usage"], dict(zip(COUNTERS, (12, 3, 0, 5))))
        self.assertEqual(record["usage_source"], "modelUsage")
        self.assertEqual(record["usage_status"], "complete")
        payload.pop("modelUsage")
        payload["usage"] = dict.fromkeys(COUNTERS, 0)
        result, record = self.invoke(payload)
        self.assertEqual(record["usage"], dict.fromkeys(COUNTERS, 0))
        self.assertEqual(record["usage_status"], "complete")

    def test_malformed_usage_never_becomes_zero(self):
        for usage in ("bad", {}, {"input_tokens":True}, {"input_tokens":-1}, {"input_tokens":"7"}):
            result, record = self.invoke({"type":"result", "subtype":"success", "is_error":False,
                                          "result":"SKIP", "usage":usage})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(record["usage_status"], "malformed")
            self.assertIsNone(record["usage"]["input_tokens"])
        result, record = self.invoke({"type":"result", "subtype":"success", "is_error":False,
                                      "result":"SKIP", "modelUsage":{MODEL:{"inputTokens":4}}})
        self.assertEqual(record["usage"]["input_tokens"], 4)
        self.assertIsNone(record["usage"]["output_tokens"])
        self.assertEqual(record["usage_status"], "malformed")

    def test_failures_record_usage_and_never_retry(self):
        payload = {"type":"result", "subtype":"success", "is_error":True,
                   "result":"SECRET PROVIDER ERROR", "usage":dict.fromkeys(COUNTERS, 2)}
        for exit_code in (0, 23):
            before = len(self.calls()) if (self.base / "calls").exists() else 0
            result, record = self.invoke(payload, exit_code=exit_code)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(record["error_code"], "provider_failed")
            self.assertEqual(record["usage"]["input_tokens"], 2)
            self.assertEqual(record["successful_calls"], 0)
            self.assertEqual(record["dedup_outcome"], "not_run")
            self.assertEqual(len(self.calls()), before+1)
        for raw in ("SECRET PROVIDER ERROR", "[]", '{"type":"result","subtype":"success","is_error":false}'):
            result, record = self.invoke(raw=raw)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(record["error_code"], "invalid_response")
        self.assertFalse((self.vault / "Inbox").exists())

    def test_model_substitution_is_rejected_and_accounted(self):
        payload = {"type":"result", "subtype":"success", "is_error":False, "result":NOTE,
                   "modelUsage":{"claude-opus-4-6":dict.fromkeys(ALIASES, 3)}}
        result, record = self.invoke(payload)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(record["error_code"], "model_mismatch")
        self.assertEqual(record["actual_models"], ["claude-opus-4-6"])
        self.assertEqual(record["usage"]["input_tokens"], 3)
        self.assertFalse((self.vault / "Inbox").exists())

    def test_concurrent_identical_writes_do_not_claim_distinct_inserts(self):
        (self.base / "response").write_text(json.dumps({"type":"result", "subtype":"success", "is_error":False, "result":NOTE}))
        processes = []
        for index in range(2):
            transcript = self.base / ("transcript-"+str(index))
            transcript.write_text("offline fixture")
            processes.append(subprocess.Popen(["bash", str(ROOT / "scripts/session-summarize.sh"),
                                               str(transcript), str(self.config), str(self.vault), "same-source"],
                                              env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
        for process in processes:
            _, errors = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, errors.decode())
        records = [json.loads(path.read_text()) for path in (self.base / "state/obsidian/summary-usage").glob("*.json")]
        self.assertEqual(len(records), 2)
        self.assertEqual([r["dedup_outcome"] for r in records], ["committed_or_identical"]*2)
        self.assertEqual(len(list((self.vault / "Inbox").glob("*-fixture-summary*.md"))), 1)

    def test_keeper_insert_identical_conflict_and_usage_correlation(self):
        payload = {"type":"result", "subtype":"success", "is_error":False, "result":NOTE}
        records = []
        for expected, text in (("committed_or_identical",NOTE), ("committed_or_identical",NOTE), ("conflict",NOTE+"Different body\n")):
            payload["result"] = text
            result, record = self.invoke(payload, source="")
            records.append(record)
            self.assertEqual(record["dedup_outcome"], expected, result.stderr)
            self.assertEqual(record["completion"], "success")
            self.assertEqual(record["successful_calls"], 1)
            self.assertEqual(result.returncode == 0, expected != "conflict")
        self.assertEqual(len({r["invocation_id"] for r in records}), 3)
        self.assertEqual(len({r["source_session_hash"] for r in records}), 1)
        self.assertEqual(len({r["source_boundary_sha256"] for r in records}), 1)


unittest.main()
TESTS
