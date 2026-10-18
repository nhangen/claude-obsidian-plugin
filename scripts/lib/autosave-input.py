#!/usr/bin/env python3
"""Prepare autosave-only model input; all limits are bytes, never token estimates."""
import collections
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

MAX_INPUT = 65536
MAX_RECORD = 1048576
MAX_EVENTS = 128
MAX_TEXT = 8192
MAX_EVENT_BYTES = 32768


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"


def texts(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(block["text"] for block in content
                         if isinstance(block, dict) and block.get("type") == "text"
                         and isinstance(block.get("text"), str))
    return ""


def redact(events):
    with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as scratch:
        for event in events:
            scratch.write(encode(event))
        scratch.flush()
        subprocess.run(["bash", str(Path(__file__).with_name("redact-secrets.sh")),
                        scratch.name], check=True)
        scratch.seek(0)
        return [json.loads(line) for line in scratch]


def event_fingerprint(event):
    return hashlib.sha256(json.dumps({"kind": event["kind"], "text": event["text"]},
                                     sort_keys=True).encode("utf-8")).hexdigest()


def segments(raw):
    parts = []
    while len(raw) > MAX_TEXT:
        end = MAX_TEXT
        while end and raw[end] & 0xC0 == 0x80:
            end -= 1
        parts.append(raw[:end].decode("utf-8"))
        raw = raw[end:]
    parts.append(raw.decode("utf-8"))
    return parts


def extract(source):
    events = collections.OrderedDict()
    summary = None
    counts = collections.Counter()
    source_bytes = 0
    with open(source, "rb") as stream:
        while True:
            line = stream.readline(MAX_RECORD + 1)
            if not line:
                break
            source_bytes += len(line)
            if len(line) > MAX_RECORD:
                while not line.endswith(b"\n"):
                    line = stream.readline(MAX_RECORD + 1)
                    source_bytes += len(line)
                    if not line:
                        break
                counts["oversized_records"] += 1
                continue
            try:
                record = json.loads(line)
            except (ValueError, UnicodeError):
                counts["invalid_records"] += 1
                continue
            if not isinstance(record, dict):
                counts["excluded_records"] += 1
                continue
            role = record.get("type")
            message = record.get("message")
            if role not in ("user", "assistant") or not isinstance(message, dict):
                counts["excluded_records"] += 1
                continue
            content = message.get("content", "")
            extracted = []
            text = texts(content)
            if text.strip():
                extracted.append((role, text, message.get("id") or record.get("uuid")))
            if role == "user" and isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        result = texts(block.get("content"))
                        if result.strip():
                            extracted.append(("tool_result", result, block.get("tool_use_id")))
            if record.get("isCompactSummary") is True and text.strip():
                summary = {"kind": "previous_summary", "text": text}
                counts["covered_by_previous_summary"] += len(events)
                events.clear()
                continue
            if not extracted:
                counts["excluded_records"] += 1
            for kind, text, identity in extracted:
                fingerprint = hashlib.sha256(text.encode("utf-8")).hexdigest()
                key = (kind, str(identity or ""), fingerprint)
                duplicate = False
                for old_key, old_event in list(events.items()):
                    if old_key == key:
                        duplicate = True
                        break
                    if identity and old_key[:2] == key[:2]:
                        if kind == "tool_result" or (kind == "assistant" and text.startswith(old_event["text"])):
                            del events[old_key]
                            counts["duplicate_or_updated_blocks"] += 1
                        elif kind == "assistant" and old_event["text"].startswith(text):
                            duplicate = True
                            break
                if duplicate:
                    counts["duplicate_or_updated_blocks"] += 1
                    continue
                events[key] = {"kind": kind, "text": text}
                while len(events) > MAX_EVENTS:
                    events.popitem(last=False)
                    counts["omitted_events"] += 1

    candidates = ([summary] if summary else []) + list(events.values())
    # Redact full values before clipping, so a boundary cannot split a credential.
    candidates = redact(candidates)
    for event in candidates:
        event["fp"] = event_fingerprint(event)
    return candidates, counts, source_bytes, summary is not None


def prepare(source, target, context=None, sent_path=None):
    candidates, counts, source_bytes, has_summary = extract(source)
    seen = set(context["seen"]) if context else None
    git = context.get("git") if context else None
    pending = [event for event in candidates if seen is None or event["fp"] not in seen]

    units = []
    for event in pending:
        raw = event["text"].encode("utf-8")
        if len(raw) > MAX_EVENT_BYTES:
            marker = "\n[... text omitted ...]\n"
            side = (MAX_TEXT - len(marker.encode("utf-8"))) // 2
            parts = [raw[:side].decode("utf-8", errors="ignore") + marker
                     + raw[-side:].decode("utf-8", errors="ignore")]
            counts["clipped_events"] += 1
        else:
            parts = segments(raw)
        rows = [{"kind": event["kind"], "text": part} if len(parts) == 1 else
                {"kind": event["kind"], "text": part, "part": f"{n}/{len(parts)}"}
                for n, part in enumerate(parts, 1)]
        units.append((event["fp"], event["kind"], rows,
                      sum(len(encode(row).encode("utf-8")) for row in rows)))

    git_rows = []
    if git and git.get("available"):
        git_rows = redact([{"kind": "local_git_evidence", "text": json.dumps(git, ensure_ascii=False)}])
    reserved = sum(len(encode(row).encode("utf-8")) for row in git_rows)

    # With carry-forward the oldest evidence goes first and the newest stays pending.
    budget = MAX_INPUT - 2048 - reserved
    total = sum(unit[3] for unit in units)
    while total > budget:
        index = -1 if seen is not None else (
            1 if has_summary and len(units) > 1 and units[0][1] == "previous_summary" else 0)
        total -= units.pop(index)[3]
        counts["omitted_events"] += 1

    sent = [unit[0] for unit in units]
    body_rows = git_rows + [row for unit in units for row in unit[2]]
    metadata = {"kind": "extraction_metadata", "policy": "autosave-v1",
                "max_input_bytes": MAX_INPUT, "max_record_bytes": MAX_RECORD,
                "max_events": MAX_EVENTS, "max_text_bytes": MAX_TEXT,
                "source_bytes": source_bytes, "payload_bytes": 0,
                "mode": "previous_summary_plus_delta" if has_summary else "bounded_conversation",
                "carry_forward": seen is not None,
                "extracted_events": len(candidates),
                "already_summarized_events": len(candidates) - len(pending),
                "pending_events": len(pending), "sent_events": len(sent),
                "retained_events": len(pending) - len(sent) if seen is not None else 0}
    metadata["omissions"] = dict(counts)
    metadata["context_incomplete"] = any(counts[key] for key in
        ("oversized_records", "invalid_records", "omitted_events", "clipped_events"))
    body = "".join(encode(row) for row in body_rows)
    for _ in range(4):
        metadata["payload_bytes"] = len((encode(metadata) + body).encode("utf-8"))
    output = encode(metadata) + body
    assert len(output.encode("utf-8")) <= MAX_INPUT
    Path(target).write_text(output, encoding="utf-8")
    if sent_path:
        Path(sent_path).write_text(json.dumps({"sent": sent}), encoding="utf-8")
    print("autosave input: source_bytes={} payload_bytes={} context_incomplete={}".format(
        source_bytes, metadata["payload_bytes"], metadata["context_incomplete"]), file=sys.stderr)

if __name__ == "__main__":
    context_path = os.environ.get("AUTOSAVE_CONTEXT_FILE")
    prepare(sys.argv[1], sys.argv[2],
            json.loads(Path(context_path).read_text(encoding="utf-8")) if context_path else None,
            os.environ.get("AUTOSAVE_SENT_FILE"))
