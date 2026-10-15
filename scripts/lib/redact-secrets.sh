#!/usr/bin/env bash
# redact-secrets.sh <file>
# Redacts credentials from a transcript file IN PLACE before session-summarize.sh
# sends it to the summarizer, so secrets pasted into a session are not copied
# into vault notes. Pattern-based: it catches the common key and token shapes
# (PEM private keys, JSON credential fields, provider tokens, bearer headers,
# JWTs, NAME_TOKEN=... style assignments), not every possible secret.
# Fails closed: exits non-zero on any error so the caller skips the save instead
# of summarizing unredacted text.
set -uo pipefail

FILE="${1:-}"
[ -n "$FILE" ] && [ -f "$FILE" ] || { echo "redact-secrets: no such file: $FILE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "redact-secrets: python3 required" >&2; exit 3; }

python3 - "$FILE" <<'PY' || exit 1
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="surrogateescape").read()
orig = text

R = "[REDACTED]"
credential_fields = r"(?:key|private_key|client_secret|secret|token|password|access_token|api_key|auth_token|clientId|keyId)"
escaped_field = re.compile(rf'''\\"{credential_fields}\\"\s*:\s*\\"''', re.I)

def redact_escaped_values(source):
    output = []
    cursor = 0
    search_from = 0
    while match := escaped_field.search(source, search_from):
        quote = match.end()
        while (quote := source.find('"', quote)) != -1:
            slash = quote - 1
            while slash >= 0 and source[slash] == "\\":
                slash -= 1
            slash_count = quote - slash - 1
            if slash_count % 4 == 1:
                output.extend((source[cursor:match.end()], R))
                cursor = quote - 1
                search_from = quote + 1
                break
            quote += 1
        else:
            search_from = match.end()
    output.append(source[cursor:])
    return "".join(output)

text = redact_escaped_values(text)

rules = [
    # PEM private keys, complete or truncated (newlines may be literal or JSON-escaped)
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----", re.S),
     "[REDACTED PRIVATE KEY]"),
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[A-Za-z0-9+/=\\n\r ]{16,}"),
     "[REDACTED PRIVATE KEY]"),
    # Well-known token shapes
    (re.compile(r"glpat-[A-Za-z0-9_\-]{16,}"), R),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"), R),
    (re.compile(r"github_pat_[A-Za-z0-9_]{30,}"), R),
    (re.compile(r"sk-[A-Za-z0-9_\-]{20,}"), R),
    (re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}"), R),
    (re.compile(r"AKIA[0-9A-Z]{16}"), R),
    (re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"), R),
    (re.compile(r"(Bearer\s+)[A-Za-z0-9._~+/=\-]{20,}", re.I), r"\1" + R),
    # Plain JSON-style credential fields, including spaces and escaped content.
    (re.compile(rf'''("{credential_fields}"\s*:\s*")((?:\\.|[^"\\])*)''', re.I),
     r"\1" + R),
    (re.compile(rf"('(?:{credential_fields})'\s*:\s*')((?:\\.|[^'\\])*)", re.I),
     r"\1" + R),
    # ENV-style assignments with secret-ish names
    (re.compile(r"""((?:[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY)[A-Za-z0-9_]*)\s*[=:]\s*["']?)([^\s"'\\<>]{8,})""", re.I),
     r"\1" + R),
]

for rx, repl in rules:
    text = rx.sub(repl, text)

if text != orig:
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(text)
PY
