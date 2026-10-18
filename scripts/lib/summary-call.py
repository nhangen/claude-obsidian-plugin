#!/usr/bin/env python3
"""Private, allowlisted accounting for the autosave model boundary."""

import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import uuid
from datetime import datetime, timezone

MODELS = {"claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"}
EFFORTS = {"low", "medium", "high"}
COUNTERS = (
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
)


def store(path, record):
    temporary = path.with_suffix(".tmp")
    with temporary.open("x", encoding="utf-8") as stream:
        os.chmod(temporary, 0o600)
        json.dump(record, stream, separators=(",", ":"))
        stream.write("\n")
    temporary.replace(path)


def fail(record, code, message):
    record["completion"] = "error"
    record["error_code"] = code
    print("obsidian summary: " + message, file=sys.stderr)
    return 1


def scalar(config, key, default):
    reader = Path(__file__).with_name("resolve-config.sh")
    result = subprocess.run(
        [
            "bash",
            "-c",
            '. "$1"; obsidian_config_value "$2"',
            "summary",
            str(reader),
            key,
        ],
        env={**os.environ, "OBSIDIAN_LOCAL_MD": config},
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else default


def auth_category():
    for variable, category in (
        ("CLAUDE_CODE_USE_BEDROCK", "bedrock"),
        ("CLAUDE_CODE_USE_VERTEX", "vertex"),
        ("CLAUDE_CODE_USE_FOUNDRY", "foundry"),
    ):
        if os.environ.get(variable) in ("1", "true"):
            return category
    return "api_key" if os.environ.get("ANTHROPIC_API_KEY") else "cli_login_or_unknown"


def account(record, payload):
    model_usage = payload.get("modelUsage")
    if isinstance(model_usage, dict) and model_usage:
        record["usage_source"] = "modelUsage"
        record["actual_models"] = sorted(
            k
            for k in model_usage
            if re.fullmatch(
                r"claude-(?:haiku|sonnet|opus|fable)-[0-9]{1,2}(?:-[0-9]{1,2})?(?:-[0-9]{8})?",
                k,
            )
        )
        aliases = (
            "inputTokens",
            "outputTokens",
            "cacheReadInputTokens",
            "cacheCreationInputTokens",
        )
        for key, alias in zip(COUNTERS, aliases):
            values = [
                row.get(alias) if isinstance(row, dict) else None
                for row in model_usage.values()
            ]
            if all(type(v) is int and v >= 0 for v in values):
                record["usage"][key] = sum(values)
        record["usage_status"] = (
            "complete"
            if all(v is not None for v in record["usage"].values())
            else "malformed"
        )
    else:
        record["usage_source"] = "usage" if "usage" in payload else None
        usage = payload.get("usage")
        if isinstance(usage, dict):
            for key in COUNTERS:
                value = usage.get(key)
                if type(value) is int and value >= 0:
                    record["usage"][key] = value
            record["usage_status"] = (
                "complete"
                if all(v is not None for v in record["usage"].values())
                else "malformed"
            )
        elif usage is not None or model_usage is not None:
            record["usage_status"] = "malformed"


def start(transcript, source):
    base = os.environ.get("XDG_STATE_HOME")
    if not base:
        home = os.environ.get("HOME")
        if not home:
            raise ValueError("HOME or XDG_STATE_HOME required")
        base = str(Path(home) / ".local/state")
    directory = Path(base) / "obsidian/summary-usage"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    invocation = str(uuid.uuid4())
    record = {
        "version": 1,
        "invocation_id": invocation,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "source_session_hash": hashlib.sha256(source.encode()).hexdigest()
        if source
        else None,
        "source_boundary_sha256": hashlib.sha256(
            Path(transcript).read_bytes()
        ).hexdigest(),
        "requested_model": None,
        "actual_models": [],
        "effort": None,
        "auth_category": auth_category(),
        "attempts": 0,
        "successful_calls": 0,
        "completion": "pending",
        "error_code": None,
        "usage_status": "missing",
        "usage_source": None,
        "usage": dict.fromkeys(COUNTERS),
        "dedup_outcome": "not_run",
    }
    path = directory / (invocation + ".json")
    store(path, record)
    print(path)


def run(record, transcript, config, path):
    with open(config, encoding="utf-8") as stream:
        if stream.readline().strip() != "---":
            return fail(
                record,
                "invalid_config",
                "config must begin with YAML frontmatter; repair it before retrying",
            )
    model = scalar(config, "summary_model", "claude-haiku-5-5")
    effort = scalar(config, "summary_effort", "low")
    if model not in MODELS:
        return fail(
            record,
            "invalid_model",
            "set summary_model to a supported exact model ID; see README",
        )
    record["requested_model"] = model
    if effort not in EFFORTS:
        return fail(
            record, "invalid_effort", "set summary_effort to low, medium, or high"
        )
    record["effort"] = effort
    args = ["claude", "--print"]
    if os.environ.get("ANTHROPIC_API_KEY"):
        args += ["--bare"]
    args += ["--disable-slash-commands", "--tools", "", "--strict-mcp-config"]
    args += [
        "--setting-sources",
        "",
        "--settings",
        json.dumps(
            {
                "availableModels": [model],
                "enforceAvailableModels": True,
                "fallbackModel": [],
            }
        ),
        "--model",
        model,
        "--effort",
        effort,
        "--output-format",
        "json",
        "--system-prompt",
        sys.stdin.read(),
        "--max-budget-usd",
        "0.10",
    ]
    record["attempts"] = 1
    store(path, record)
    with open(transcript, "rb") as stream:
        try:
            result = subprocess.run(
                args,
                stdin=stream,
                capture_output=True,
                env={
                    **os.environ,
                    "OBSIDIAN_SUMMARIZING": "1",
                    "CLAUDE_CODE_EFFORT_LEVEL": effort,
                },
            )
        except OSError:
            return fail(
                record,
                "cli_unavailable",
                "install a CLI supporting --model, --effort and JSON output",
            )
    try:
        payload = json.loads(result.stdout)
        if not isinstance(payload, dict):
            raise ValueError()
    except (ValueError, UnicodeError):
        return fail(
            record,
            "invalid_response" if result.returncode == 0 else "provider_failed",
            "summary call failed or returned invalid JSON; check CLI authentication/model availability; no retry performed",
        )
    account(record, payload)
    provider_success = (
        result.returncode == 0
        and payload.get("type") == "result"
        and payload.get("is_error") is False
        and payload.get("subtype") == "success"
    )
    record["successful_calls"] = int(provider_success)
    model_usage = payload.get("modelUsage")
    if isinstance(model_usage, dict) and any(k != model for k in model_usage):
        return fail(
            record,
            "model_mismatch",
            "CLI used an unexpected model; summary rejected; check managed model policy",
        )
    if not provider_success:
        return fail(
            record,
            "provider_failed",
            "summary call failed; verify authentication, summary_model availability and budget; no retry performed",
        )
    if not isinstance(payload.get("result"), str):
        return fail(
            record,
            "invalid_response",
            "CLI JSON has no text result; update the CLI or check its output contract",
        )
    record["completion"] = "success"
    record["successful_calls"] = 1
    print(payload["result"])
    return 0


def main():
    os.umask(0o077)
    command, *args = sys.argv[1:]
    if command == "start":
        start(*args)
        return 0
    path = Path(args[0])
    record = json.loads(path.read_text())
    if command == "run":
        try:
            return run(record, *args[1:], path)
        finally:
            store(path, record)
    if command == "finish":
        record["exit_code"] = int(args[1])
        record["dedup_outcome"] = args[2]
        if record["completion"] == "pending":
            record["completion"] = "error"
            record["error_code"] = "preparation_failed"
        store(path, record)
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError):
        print(
            "obsidian summary: private usage record unavailable; check state directory permissions",
            file=sys.stderr,
        )
        sys.exit(1)
