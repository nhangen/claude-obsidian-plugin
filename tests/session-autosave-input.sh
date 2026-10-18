#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" <<'TEST_PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="autosave-input-") as temporary:
    case = Path(temporary)
    (case / "bin").mkdir()
    (case / "vault").mkdir()
    (case / "home").mkdir()
    model = case / "bin" / "claude"
    model.write_text("""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

Path(os.environ["CAPTURE_INPUT"]).write_bytes(sys.stdin.buffer.read())
result = "SKIP"
if os.environ.get("SAVE_NOTE") == "true":
    result = "\\n".join([
        "---", "vault_folder: Inbox/", "slug: bounded-input",
        "session_intent: execution", "capture_action: project_note",
        "research_state_change: none", "---", "# Bounded input",
        "A decision survived.", ""
    ])
print(json.dumps({"type": "result", "subtype": "success",
                  "is_error": False, "result": result}))
""")
    model.chmod(0o755)
    config = case / "config.md"
    config.write_text(f"---\nvault_path: {case / 'vault'}\nauto_save: true\nkeeper_autostart: false\n---\n")
    capture = case / "input.jsonl"
    source = case / "source.jsonl"
    env = dict(os.environ, PATH=str(case / "bin") + os.pathsep + os.environ["PATH"],
               HOME=str(case / "home"), XDG_STATE_HOME=str(case / "state"), XDG_CONFIG_HOME=str(case / "home" / ".config"),
               OBSIDIAN_LOCAL_MD=str(config), OBSIDIAN_SUMMARIZING="",
               ANTHROPIC_API_KEY="", CAPTURE_INPUT=str(capture), TMPDIR=str(case))

    def write(records):
        source.write_text("".join(json.dumps(record) + "\n" for record in records))

    def message(role, text, **extra):
        return dict(type=role, message={"content": text}, **extra)

    def run(hook=False, save=False):
        capture.unlink(missing_ok=True)
        if hook:
            subprocess.run(["bash", "-c", 'trap wait EXIT; source "$0" --capture',
                            str(root / "scripts/session-save.sh")],
                           input=json.dumps({"transcript_path": str(source)}),
                           text=True, env=dict(env, SAVE_NOTE=str(save).lower()), check=True)
        else:
            scratch = case / "scratch.jsonl"
            scratch.write_bytes(source.read_bytes())
            subprocess.run(["bash", str(root / "scripts/session-summarize.sh"),
                            str(scratch), str(config), str(case / "vault")],
                           env=dict(env, SAVE_NOTE=str(save).lower()), check=True)
            assert not scratch.exists(), "worker leaked scratch file"
        data = capture.read_bytes()
        rows = [json.loads(line) for line in data.splitlines()]
        assert len(data) <= 65536
        assert rows[0]["payload_bytes"] == len(data)
        assert source.exists(), "worker deleted original transcript"
        return rows[0], rows[1:], data.decode()

    blobs = [{"type": kind, "request": "INSTRUMENTATION_SCHEMA " * 1000}
             for kind in ("api-request", "progress", "stream_event") for _ in range(30)]
    write([message("user", "Please implement safe extraction.")] + blobs + [
        {"type": "assistant", "message": {"id": "a1", "content": [
            {"type": "text", "text": "Decision: use atomic replacement."},
            {"type": "tool_use", "name": "Bash", "input": {"schema": "SCHEMA_BLOB"}},
            {"type": "thinking", "thinking": "HIDDEN_REASONING"}]}},
        {"type": "assistant", "message": {"id": "a1", "content": [
            {"type": "text", "text": "Decision: use atomic replacement. Keep retries bounded."}]}},
        {"type": "assistant", "message": {"id": "a1", "content": [
            {"type": "text", "text": "Separate block: preserve the recovery plan."}]}},
        message("user", [{"type": "tool_result", "tool_use_id": "t1", "content":
                         "Local fixture suite passed. Commit abcdef1234567890. API_KEY=fictional-secret-value"}]),
        message("user", [{"type": "tool_result", "tool_use_id": "t1", "content":
                         "Local fixture suite passed. Commit abcdef1234567890. API_KEY=fictional-secret-value"}])])
    original = source.read_bytes()
    meta, events, text = run(hook=True)
    assert source.read_bytes() == original
    assert "Decision: use atomic replacement. Keep retries bounded." in text
    assert "Separate block: preserve the recovery plan." in text
    assert text.count("Decision:") == 1 and text.count("Local fixture suite passed") == 1
    assert "abcdef1234567890" in text and "[REDACTED]" in text
    for excluded in ("INSTRUMENTATION_SCHEMA", "SCHEMA_BLOB", "HIDDEN_REASONING", "fictional-secret-value"):
        assert excluded not in text, excluded
    assert meta["source_bytes"] > meta["payload_bytes"] * 100
    assert not meta["context_incomplete"]

    credential_text = (
        'export API_KEY="fictional-quoted-key"; KEEP after double quote\n'
        "PASSWORD='fictional multiword password'; KEEP after single quote\n"
        'CLIENT_SECRET="fictional \\"embedded\\" quotes and \\\\ slashes"; KEEP escaped boundary\n'
        'AUTH_TOKEN="fictional\nmultiline credential"; KEEP multiline boundary\n'
        'Authorization: Bearer\tFICTIONALBEARERabcdefghijklmnopqrs\n'
        'KEEP credential context'
    )
    credential_text += ('API_SECRET="fictional' + chr(92) + chr(10)
                        + 'continued-secret"; KEEP continued boundary\n')
    write([message("user", credential_text),
           message("user", [{"type": "tool_result", "tool_use_id": "quoted", "content":
                            'PASSWORD="fictional result password"; KEEP result boundary'}])])
    meta, events, text = run(hook=True)
    decoded = "\n".join(event["text"] for event in events)
    for secret in ("fictional-quoted-key", "fictional multiword password", "fictional",
                   "FICTIONALBEARERabcdefghijklmnopqrs"):
        assert secret not in decoded, "credential survived production extraction"
    for context in ("KEEP after double quote", "KEEP after single quote", "KEEP escaped boundary",
                    "KEEP multiline boundary", "KEEP credential context", "KEEP result boundary"):
        assert context in decoded, "redaction consumed adjacent context"
    assert 'CLIENT_SECRET=[REDACTED]; KEEP escaped boundary' in decoded
    assert 'AUTH_TOKEN=[REDACTED]; KEEP multiline boundary' in decoded
    assert 'PASSWORD=[REDACTED]; KEEP result boundary' in decoded
    assert 'API_SECRET=[REDACTED]; KEEP continued boundary' in decoded
    assert 'Bearer\t[REDACTED]' in decoded
    assert not meta["context_incomplete"]

    write([message("user", "Before compaction, no longer needed."),
           message("user", "Prior decision: use atomic replacement. Commit abcdef1234567890.", isCompactSummary=True),
           message("assistant", "New delta: offline fixtures pass.")])
    meta, events, text = run()
    assert meta["mode"] == "previous_summary_plus_delta"
    assert events[0]["kind"] == "previous_summary"
    assert "Prior decision:" in text and "New delta:" in text
    assert "Before compaction" not in text

    write([message("user", "Earlier context " + "🦉" * 3000 + str(i)) for i in range(150)] + [
        message("assistant", "Final significant decision: cap input bytes. Commit 1234567890abcdef."),
        message("user", [{"type": "tool_result", "tool_use_id": "large", "content":
            "head " + "z" * 18000 + " password=another-fictional-secret tail PASS"}])])
    with source.open("a") as stream:
        stream.write("{bad json}\n")
        stream.write(json.dumps(message("user", "oversized " + "x" * 1048576)) + "\n")
    meta, events, text = run(save=True)
    assert meta["context_incomplete"]
    assert meta["omissions"]["omitted_events"] > 0
    assert meta["omissions"]["clipped_events"] > 0
    assert meta["omissions"]["oversized_records"] == 1
    assert meta["omissions"]["invalid_records"] == 1
    assert "Final significant decision" in text and "1234567890abcdef" in text
    assert "tail PASS" in text and "another-fictional-secret" not in text
    notes = list((case / "vault" / "Inbox").glob("*-bounded-input.md"))
    assert len(notes) == 1
    assert '"context_incomplete":true' in notes[0].read_text()
    assert "## Autosave Input Coverage" in notes[0].read_text()
    assert "bounded-input" in next((case / "vault" / "Daily").glob("*.md")).read_text()
print("autosave input offline production-path tests passed")
TEST_PY
