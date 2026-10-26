#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = Path(os.environ["OBSIDIAN_MCP_CAPTURE_TEST_ROOT"])
DEFAULT_BUNDLE = TEST_ROOT / "default-client"
IDENTITY = {
    "GIT_AUTHOR_NAME": "Test Author",
    "GIT_AUTHOR_EMAIL": "author@example.invalid",
    "GIT_COMMITTER_NAME": "Test Committer",
    "GIT_COMMITTER_EMAIL": "committer@example.invalid",
}


FAKE_BRIDGE = r"""#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from pathlib import Path

scenario = os.environ.get("FAKE_SCENARIO", "committed")
Path(os.environ["FAKE_STARTED"]).write_text("started")
Path(os.environ["FAKE_BRIDGE_PID"]).write_text(str(os.getpid()))

def send(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    request = json.loads(line)
    with Path(os.environ["FAKE_REQUESTS"]).open("a") as handle:
        handle.write(request.get("method", "") + "\n")
    if request.get("method") == "initialize":
        Path(os.environ["FAKE_INITIALIZE_PROTOCOL"]).write_text(request["params"]["protocolVersion"])
        result = {"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"claude-obsidian-mcp","version":os.environ.get("FAKE_VERSION", "0.2.0")}}
        if scenario == "protocol-mismatch":
            result["protocolVersion"] = "2026-07-28"
        elif scenario == "protocol-missing":
            result.pop("protocolVersion")
        elif scenario == "tools-capability-missing":
            result["capabilities"] = {}
        elif scenario == "tools-capability-malformed":
            result["capabilities"]["tools"] = []
        send({"jsonrpc":"2.0","id":request["id"],"result":result})
    elif request.get("method") == "notifications/initialized":
        continue
    elif request.get("method") == "tools/list":
        properties = {name:{"type":"string"} for name in ("content","section","target_path","skip_if_hash","idempotency_key")}
        if scenario == "missing-capability":
            properties.pop("target_path")
        send({"jsonrpc":"2.0","id":request["id"],"result":{"tools":[{"name":"obsidian_daily_append","inputSchema":{"type":"object","properties":properties}}]}})
    elif request.get("method") == "tools/call":
        arguments = request["params"]["arguments"]
        with Path(os.environ["FAKE_CALLS"]).open("a") as handle:
            handle.write(json.dumps(arguments, separators=(",", ":")) + "\n")
        target = arguments["target_path"]
        key = arguments["idempotency_key"]
        outcome = {"status":"committed","request_id":"fake-request","idempotency_key":key,"path":target,"affected_paths":[target],"warnings":[],"recovery":{"required":False,"action":""},"error_code":None,"retryable":False}
        is_error = False
        exit_after_send = False
        if scenario == "skipped":
            outcome["status"] = "skipped"
        elif scenario == "conflict":
            outcome.update(status="conflict", error_code="IDEMPOTENCY_CONFLICT")
            is_error = True
        elif scenario == "heading-conflict":
            outcome.update(status="conflict", error_code="CONFLICT", recovery={"required":True,"action":"untrusted-action-text"})
            is_error = True
        elif scenario == "partial":
            outcome.update(status="partial", error_code="PARTIAL", retryable=True, recovery={"required":True,"action":"untrusted-action-text"})
            is_error = True
        elif scenario == "failed":
            outcome.update(status="failed", error_code="WRITE_FAILED")
            is_error = True
        elif scenario == "contradictory":
            outcome["error_code"] = "WRITE_FAILED"
        elif scenario == "unexpected-outcome-field":
            outcome["detail"] = "uncontracted success detail"
        elif scenario == "unexpected-path":
            outcome["path"] = "Other/Note.md"
            outcome["affected_paths"] = ["Other/Note.md"]
        elif scenario == "unknown-error-code":
            outcome.update(status="failed", error_code="UNTRUSTED_CODE")
            is_error = True
        elif scenario == "invalid-unicode":
            outcome["request_id"] = "\ud800"
        elif scenario == "timeout-leader-exit":
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            Path(os.environ["FAKE_CHILD_PID"]).write_text(str(child.pid))
            sys.exit(0)
        elif scenario == "leader-exit-success-with-child":
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            Path(os.environ["FAKE_CHILD_PID"]).write_text(str(child.pid))
            exit_after_send = True
        elif scenario == "malformed":
            sys.stderr.write(os.environ["FAKE_SECRET"])
            sys.stderr.flush()
            sys.stdout.write("not-json\n")
            sys.stdout.flush()
            continue
        elif scenario == "delayed-success":
            time.sleep(11)
        elif scenario == "permanent-stall":
            time.sleep(60)
        send({"jsonrpc":"2.0","id":request["id"],"result":{"content":[],"isError":is_error,"structuredContent":outcome}})
        if exit_after_send:
            sys.exit(0)
"""


class CaptureCommitTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "codex/939-mcp-capture")
        (self.repo / "change.txt").write_text("change\n")
        self.git("add", "change.txt")
        env = self.environment(
            GIT_AUTHOR_DATE="2026-10-09T12:34:00-04:00",
            GIT_COMMITTER_DATE="2026-10-09T12:34:00-04:00",
        )
        self.git("commit", "-m", "fixture", env=env)
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.git(
            "remote", "add", "origin", "git@github.com:example-owner/example-repo.git"
        )
        self.calls = self.root / "calls.jsonl"
        self.requests = self.root / "requests.txt"
        self.initialize_protocol_path = self.root / "initialize-protocol.txt"
        self.started = self.root / "started"
        self.child_pid = self.root / "child.pid"
        self.bridge_pid = self.root / "bridge.pid"
        self.bundle_counter = 0

    def tearDown(self):
        self.temp.cleanup()

    def environment(self, **updates):
        env = os.environ.copy()
        env.pop("OBSIDIAN_MCP_CAPTURE_BRIDGE_TIMEOUT_SECONDS", None)
        env.update(IDENTITY)
        env.update(
            {"HOME": str(self.home), "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C.UTF-8"}
        )
        env.update(updates)
        return env

    def git(self, *arguments, env=None):
        return subprocess.run(
            ["git", "-C", str(self.repo), *arguments],
            env=env or self.environment(),
            check=True,
            capture_output=True,
            text=True,
        )

    def event(self, context=None, **updates):
        payload = {
            "schemaVersion": 1,
            "event": "git.commit",
            "outcome": "success",
            "repository": str(self.repo),
            "commit": self.commit,
            "context": context
            or [
                "Implemented the bounded capture consumer.",
                "Verified the packed production entry point.",
            ],
        }
        payload.update(updates)
        return payload

    def bundle(self):
        self.bundle_counter += 1
        destination = self.root / f"bundle-{self.bundle_counter}"
        shutil.copytree(DEFAULT_BUNDLE, destination)
        bridge = destination / "bin/obsidian-mcp-write"
        bridge.write_text(FAKE_BRIDGE)
        bridge.chmod(0o755)
        return destination

    def run_capture(
        self,
        payload=None,
        *,
        raw=None,
        scenario="committed",
        version=None,
        timeout=20,
        secret="",
        bridge_timeout=None,
        oversized_producer_output=False,
        contract_mutator=None,
    ):
        bundle = self.bundle()
        if contract_mutator is not None:
            contract_path = bundle / "contract.json"
            contract = json.loads(contract_path.read_text())
            contract_mutator(contract)
            contract_bytes = (json.dumps(contract, indent=2) + "\n").encode()
            contract_path.write_bytes(contract_bytes)
            manifest_path = bundle / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["pinnedServer"]["contractSha256"] = hashlib.sha256(
                contract_bytes
            ).hexdigest()
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        if oversized_producer_output:
            producer = bundle / "bin/obsidian-mcp-commit-event"
            producer.write_text(
                "#!/usr/bin/env python3\nimport os\nos.write(1, b'x' * 131072)\n"
            )
            producer.chmod(0o755)
        env = self.environment(
            FAKE_SCENARIO=scenario,
            FAKE_STARTED=str(self.started),
            FAKE_CALLS=str(self.calls),
            FAKE_REQUESTS=str(self.requests),
            FAKE_INITIALIZE_PROTOCOL=str(self.initialize_protocol_path),
            FAKE_CHILD_PID=str(self.child_pid),
            FAKE_BRIDGE_PID=str(self.bridge_pid),
            FAKE_SECRET=secret,
        )
        if version is not None:
            env["FAKE_VERSION"] = version
        if bridge_timeout is not None:
            env["OBSIDIAN_MCP_CAPTURE_BRIDGE_TIMEOUT_SECONDS"] = bridge_timeout
        input_text = (
            raw
            if raw is not None
            else json.dumps(payload if payload is not None else self.event())
        )
        return subprocess.run(
            [str(bundle / "bin/obsidian-mcp-capture-commit")],
            input=input_text,
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )

    def assert_error(self, result, code):
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, f"error:{code}\n")

    def failure_envelope(self, result):
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertEqual(result.stdout, "")
        return json.loads(result.stderr)

    def call_records(self):
        if not self.calls.exists():
            return []
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def request_methods(self):
        if not self.requests.exists():
            return []
        return self.requests.read_text().splitlines()

    def initialize_protocol(self):
        if not self.initialize_protocol_path.exists():
            return None
        return self.initialize_protocol_path.read_text()

    def test_success_uses_canonical_target_and_stable_request(self):
        result = self.run_capture(self.event())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.initialize_protocol(), "2025-11-25")
        self.assertEqual(
            json.loads(result.stdout),
            {
                "status": "committed",
                "path": "Projects/Development/example-owner/example-repo/2026-10-09.md",
            },
        )
        call = self.call_records()[0]
        self.assertEqual(
            call["target_path"],
            "Projects/Development/example-owner/example-repo/2026-10-09.md",
        )
        self.assertEqual(call["section"], f"## 12:34 - {self.commit}")
        self.assertEqual(call["skip_if_hash"], self.commit)
        self.assertNotEqual(call["skip_if_hash"], self.commit[:8])
        self.assertIn('Branch: "codex/939-mcp-capture"', call["content"])
        self.assertIn("Implemented the bounded capture consumer.", call["content"])

    def test_exact_replay_skip_is_reported_separately(self):
        result = self.run_capture(self.event(), scenario="skipped")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "skipped")

    def test_bundle_keeps_legacy_hash_interoperability_unproven(self):
        manifest = json.loads((DEFAULT_BUNDLE / "manifest.json").read_text())
        capture = manifest["commitCapture"]
        self.assertIs(capture["defaultActivated"], False)
        self.assertEqual(capture["legacyHashInteroperability"], "unproven")
        self.assertIs(capture["automaticHistoricalBackfill"], False)

    def test_changed_context_keeps_key_and_conflict_is_not_success(self):
        first = self.run_capture(self.event(["first context"]))
        self.assertEqual(first.returncode, 0, first.stderr)
        first_call = self.call_records()[-1]
        second = self.run_capture(self.event(["changed context"]), scenario="conflict")
        second_call = self.call_records()[-1]
        envelope = self.failure_envelope(second)
        self.assertEqual(envelope["status"], "conflict")
        self.assertEqual(envelope["error_code"], "IDEMPOTENCY_CONFLICT")
        self.assertTrue(envelope["manual_verification_required"])
        self.assertEqual(
            envelope["recovery"]["guidance"],
            "verify_existing_idempotency_record",
        )
        self.assertEqual(first_call["idempotency_key"], second_call["idempotency_key"])
        self.assertEqual(envelope["idempotency_key"], second_call["idempotency_key"])
        self.assertNotEqual(first_call["content"], second_call["content"])

    def test_heading_conflict_requires_note_identity_verification_not_an_idempotency_record(
        self,
    ):
        result = self.run_capture(self.event(), scenario="heading-conflict")
        envelope = self.failure_envelope(result)
        self.assertEqual(envelope["status"], "conflict")
        self.assertEqual(envelope["error_code"], "CONFLICT")
        self.assertEqual(envelope["path"], self.call_records()[0]["target_path"])
        self.assertEqual(envelope["affected_paths"], [envelope["path"]])
        self.assertFalse(envelope["retryable"])
        self.assertTrue(envelope["manual_verification_required"])
        self.assertEqual(
            envelope["recovery"],
            {
                "required": True,
                "guidance": "verify_existing_note_commit_identity",
            },
        )
        self.assertNotIn("untrusted-action-text", result.stderr + result.stdout)

    def test_mtf_builder_is_the_only_target_override(self):
        self.git(
            "remote", "set-url", "origin", "git@github.com:altamira2/mtf-builder.git"
        )
        result = self.run_capture(self.event())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.call_records()[0]["target_path"],
            "Altamira/mtf-builder/commits/2026-10-09-mtf-builder-commits.md",
        )

    def test_missing_failed_and_malformed_events_do_not_start_bridge(self):
        for raw in ("", "not-json", json.dumps(self.event(outcome="failure"))):
            with self.subTest(raw=raw[:20]):
                if self.started.exists():
                    self.started.unlink()
                result = self.run_capture(raw=raw)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertFalse(self.started.exists())

    def test_oversized_producer_output_is_bounded_before_bridge(self):
        result = self.run_capture(self.event(), oversized_producer_output=True)
        self.assert_error(result, "EVENT_REJECTED")
        self.assertFalse(self.started.exists())

    def test_discovered_tool_and_live_version_gate_before_write(self):
        missing = self.run_capture(self.event(), scenario="missing-capability")
        self.assert_error(missing, "CAPABILITY_UNAVAILABLE")
        self.assertEqual(self.call_records(), [])
        self.started.unlink()
        version = self.run_capture(self.event(), version="0.1.15")
        self.assert_error(version, "SERVER_VERSION_MISMATCH")
        self.assertEqual(self.call_records(), [])

    def test_mismatched_initialize_protocol_stops_before_initialized_notification(self):
        result = self.run_capture(self.event(), scenario="protocol-mismatch")
        self.assert_error(result, "PROTOCOL_VERSION_MISMATCH")
        self.assertEqual(self.request_methods(), ["initialize"])
        self.assertEqual(self.call_records(), [])

    def test_absent_initialize_protocol_stops_before_initialized_notification(self):
        result = self.run_capture(self.event(), scenario="protocol-missing")
        self.assert_error(result, "PROTOCOL_VERSION_MISMATCH")
        self.assertEqual(self.request_methods(), ["initialize"])
        self.assertEqual(self.call_records(), [])

    def test_missing_tools_capability_stops_before_initialized_notification(self):
        result = self.run_capture(self.event(), scenario="tools-capability-missing")
        self.assert_error(result, "CAPABILITY_UNAVAILABLE")
        self.assertEqual(self.request_methods(), ["initialize"])
        self.assertEqual(self.call_records(), [])

    def test_malformed_tools_capability_stops_before_initialized_notification(self):
        result = self.run_capture(self.event(), scenario="tools-capability-malformed")
        self.assert_error(result, "CAPABILITY_UNAVAILABLE")
        self.assertEqual(self.request_methods(), ["initialize"])
        self.assertEqual(self.call_records(), [])

    def test_missing_or_malformed_http_matrix_stops_before_bridge(self):
        def missing_matrix(contract):
            contract["protocol"].pop("clientMatrix")

        def malformed_matrix(contract):
            contract["protocol"]["clientMatrix"] = [
                {
                    "protocolRevision": "2025-11-25",
                    "transport": "streamable-http",
                }
            ]

        for mutator in (missing_matrix, malformed_matrix):
            with self.subTest(mutator=mutator.__name__):
                result = self.run_capture(self.event(), contract_mutator=mutator)
                self.assert_error(result, "BUNDLE_INVALID")
                self.assertFalse(self.started.exists())
                self.assertEqual(self.request_methods(), [])

    def test_planned_or_unapproved_http_revision_stops_before_bridge(self):
        def planned_http(contract):
            for entry in contract["protocol"]["clientMatrix"]:
                if (
                    entry["protocolRevision"] == "2025-11-25"
                    and entry["transport"] == "streamable-http"
                ):
                    entry["status"] = "planned"

        def planned_stdio(contract):
            for entry in contract["protocol"]["clientMatrix"]:
                if (
                    entry["protocolRevision"] == "2025-11-25"
                    and entry["transport"] == "stdio"
                ):
                    entry["status"] = "planned"

        def missing_http_leg(contract):
            contract["protocol"]["clientMatrix"] = [
                entry
                for entry in contract["protocol"]["clientMatrix"]
                if not (
                    entry["protocolRevision"] == "2025-11-25"
                    and entry["transport"] == "streamable-http"
                )
            ]

        def missing_stdio_leg(contract):
            contract["protocol"]["clientMatrix"] = [
                entry
                for entry in contract["protocol"]["clientMatrix"]
                if not (
                    entry["protocolRevision"] == "2025-11-25"
                    and entry["transport"] == "stdio"
                )
            ]

        def absent_from_compatibility_revisions(contract):
            contract["protocol"]["compatibilityRevisions"] = []

        for mutator in (
            planned_http,
            planned_stdio,
            missing_http_leg,
            missing_stdio_leg,
            absent_from_compatibility_revisions,
        ):
            with self.subTest(mutator=mutator.__name__):
                result = self.run_capture(self.event(), contract_mutator=mutator)
                self.assert_error(result, "CAPABILITY_UNAVAILABLE")
                self.assertFalse(self.started.exists())
                self.assertEqual(self.request_methods(), [])

    def test_partial_and_failed_outcomes_preserve_safe_recovery_evidence(self):
        partial = self.failure_envelope(
            self.run_capture(self.event(), scenario="partial")
        )
        call = self.call_records()[-1]
        self.assertEqual(partial["status"], "partial")
        self.assertEqual(partial["error_code"], "PARTIAL")
        self.assertTrue(partial["retryable"])
        self.assertTrue(partial["recovery"]["required"])
        self.assertTrue(partial["manual_verification_required"])
        self.assertEqual(partial["affected_paths"], [call["target_path"]])
        self.assertEqual(partial["idempotency_key"], call["idempotency_key"])
        self.assertEqual(
            partial["recovery"]["guidance"],
            "verify_authoritative_path_then_retry_same_key",
        )
        self.assertEqual(set(partial["recovery"]), {"required", "guidance"})
        self.assertNotIn("untrusted-action-text", json.dumps(partial))

        failed = self.failure_envelope(
            self.run_capture(self.event(), scenario="failed")
        )
        self.assertEqual(failed["status"], "failed")
        self.assertEqual(failed["error_code"], "WRITE_FAILED")
        self.assertFalse(failed["retryable"])
        self.assertEqual(failed["recovery"]["guidance"], "inspect_failure_before_retry")

    def test_invalid_post_dispatch_outcomes_are_ambiguous_not_success(self):
        for scenario in (
            "contradictory",
            "unexpected-outcome-field",
            "unexpected-path",
            "unknown-error-code",
            "invalid-unicode",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_capture(self.event(), scenario=scenario)
                envelope = self.failure_envelope(result)
                call = self.call_records()[-1]
                self.assertEqual(envelope["status"], "ambiguous")
                self.assertEqual(envelope["error_code"], "OUTCOME_UNKNOWN")
                self.assertTrue(envelope["manual_verification_required"])
                self.assertEqual(envelope["idempotency_key"], call["idempotency_key"])
                self.assertEqual(envelope["path"], call["target_path"])
                self.assertEqual(
                    envelope["recovery"]["guidance"],
                    "verify_authoritative_path_then_retry_same_key",
                )

    def test_production_default_allows_write_longer_than_old_deadline(self):
        started = time.monotonic()
        result = self.run_capture(self.event(), scenario="delayed-success", timeout=20)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 10.5)
        self.assertEqual(json.loads(result.stdout)["status"], "committed")

    def test_timeout_override_is_strictly_bounded(self):
        for value in ("0", "301", "1.5", "slow"):
            with self.subTest(value=value):
                if self.started.exists():
                    self.started.unlink()
                result = self.run_capture(self.event(), bridge_timeout=value)
                self.assert_error(result, "CONFIG_INVALID")
                self.assertFalse(self.started.exists())

    def test_timeout_kills_descendant_after_bridge_leader_exits(self):
        result = self.run_capture(
            self.event(),
            scenario="timeout-leader-exit",
            bridge_timeout="1",
            timeout=10,
        )
        envelope = self.failure_envelope(result)
        self.assertEqual(envelope["status"], "ambiguous")
        self.assertEqual(envelope["client_error"], "BRIDGE_TIMEOUT")
        self.assertFalse(envelope["retryable"])
        self.assertTrue(envelope["manual_verification_required"])
        call = self.call_records()[-1]
        self.assertEqual(envelope["idempotency_key"], call["idempotency_key"])
        self.assertEqual(envelope["path"], call["target_path"])
        self.assertEqual(
            envelope["recovery"]["guidance"],
            "verify_authoritative_path_then_retry_same_key",
        )
        child_pid = self.child_pid.read_text()
        status = subprocess.run(
            ["ps", "-o", "stat=", "-p", child_pid],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertTrue(
            not status.stdout.strip() or status.stdout.strip().startswith("Z"),
            status.stdout,
        )

    def test_permanent_bridge_stall_is_finite_and_clean(self):
        started = time.monotonic()
        result = self.run_capture(
            self.event(),
            scenario="permanent-stall",
            bridge_timeout="1",
            timeout=10,
        )
        elapsed = time.monotonic() - started
        envelope = self.failure_envelope(result)
        self.assertEqual(envelope["status"], "ambiguous")
        self.assertEqual(envelope["client_error"], "BRIDGE_TIMEOUT")
        self.assertLess(elapsed, 5)
        bridge_pid = self.bridge_pid.read_text()
        status = subprocess.run(
            ["ps", "-o", "stat=", "-p", bridge_pid],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertTrue(
            not status.stdout.strip() or status.stdout.strip().startswith("Z"),
            status.stdout,
        )

    def test_successful_leader_exit_reaps_descendant_after_grace(self):
        result = self.run_capture(
            self.event(), scenario="leader-exit-success-with-child", timeout=10
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        child_pid = self.child_pid.read_text()
        status = subprocess.run(
            ["ps", "-o", "stat=", "-p", child_pid],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertTrue(
            not status.stdout.strip() or status.stdout.strip().startswith("Z"),
            status.stdout,
        )

    def test_diagnostics_never_echo_bridge_or_context_secrets(self):
        secret = "do-not-print-this-secret"
        result = self.run_capture(
            self.event([secret]), scenario="malformed", secret=secret
        )
        envelope = self.failure_envelope(result)
        self.assertEqual(envelope["status"], "ambiguous")
        self.assertEqual(envelope["client_error"], "BRIDGE_PROTOCOL")
        self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
