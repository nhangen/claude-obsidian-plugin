#!/bin/bash
# TEST-TYPE: regression

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK="$ROOT/scripts/pack-obsidian-mcp-client.py"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)" || fail "mktemp -d failed"
trap 'rm -rf "$tmp"' EXIT

bundle="$tmp/packed-client"
python3 "$PACK" --output "$bundle"
python3 "$PACK" --output "$bundle"

test -x "$bundle/bin/obsidian-mcp-read" || fail "read launcher missing"
test -x "$bundle/bin/obsidian-mcp-write" || fail "write launcher missing"
test -x "$bundle/bin/obsidian-mcp-commit-event" || fail "commit-event producer missing"
test -x "$bundle/bin/obsidian-mcp-capture-commit" || fail "commit capture consumer missing"
test -x "$bundle/bin/obsidian-mcp-client-install" || fail "client lifecycle installer missing"
test -f "$bundle/manifest.json" || fail "manifest missing"
test -f "$bundle/contract.json" || fail "pinned contract missing"
test -f "$bundle/release.json" || fail "release metadata missing"
test -f "$bundle/README.md" || fail "README missing"
test -x "$bundle/vendor/mcp-remote-read/xdg-open" || fail "Linux browser helper lost executable permission"

python3 - "$bundle/manifest.json" "$bundle/contract.json" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
contract_bytes = pathlib.Path(sys.argv[2]).read_bytes()
assert manifest["bundleVersion"] == 1
assert manifest["mcpRemotePackage"] == "mcp-remote@0.14.3"
assert manifest["pinnedServer"]["release"] == "mcp-v0.2.0"
assert manifest["pinnedServer"]["contractVersion"] == "0.1.3"
assert len(manifest["pinnedServer"]["contractSha256"]) == 64
assert hashlib.sha256(contract_bytes).hexdigest() == manifest["pinnedServer"]["contractSha256"]
daily_properties = json.loads(contract_bytes)["tools"]["obsidian_daily_append"]["inputSchema"]["properties"]
assert {"target_path", "skip_if_hash", "init_content"} <= set(daily_properties)
assert set(manifest["profiles"]) == {"read", "write"}
assert manifest["profiles"]["read"]["requiredScopes"] == ["vault:read", "repo:read"]
assert manifest["profiles"]["write"]["requiredScopes"] == ["vault:write"]
assert manifest["commitEvent"] == {
    "producer": "bin/obsidian-mcp-commit-event",
    "schemaVersion": 1,
    "requiresSuccessfulEvent": True,
    "writesVault": False,
}
assert manifest["commitCapture"] == {
    "consumer": "bin/obsidian-mcp-capture-commit",
    "eventProducer": "bin/obsidian-mcp-commit-event",
    "writeLauncher": "bin/obsidian-mcp-write",
    "contract": "contract.json",
    "inputSchemaVersion": 1,
    "writesVault": True,
    "defaultActivated": False,
    "legacyHashInteroperability": "unproven",
    "automaticHistoricalBackfill": False,
}
PY

python3 - "$bundle" <<'PY'
import hashlib
import json
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
metadata_bytes = (root / "release.json").read_bytes()
metadata = json.loads(metadata_bytes)
inventory = sorted(metadata["files"], key=lambda item: item["path"])
canonical = json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode()
assert metadata["formatVersion"] == 1
assert metadata["releaseId"] == hashlib.sha256(canonical).hexdigest()
assert metadata["inventorySha256"] == metadata["releaseId"]
assert "release.json" not in {entry["path"] for entry in inventory}
assert metadata["captureDefaults"] == {
    "automaticHistoricalBackfill": False,
    "defaultActivated": False,
}
for entry in inventory:
    path = root / entry["path"]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]
    assert path.stat().st_size == entry["size"]
    assert stat.S_IMODE(path.stat().st_mode) == entry["mode"]
PY

if "$bundle/bin/obsidian-mcp-commit-event" </dev/null >"$tmp/no-event.out" 2>"$tmp/no-event.err"; then
  fail "packed commit-event producer inferred a commit without an event"
fi
test ! -s "$tmp/no-event.out" || fail "missing event produced metadata"

provenance="$tmp/provenance"
mkdir -p "$provenance"
cp "$ROOT/packages/client/catalog.json" "$provenance/catalog.json"
cp "$ROOT/packages/mcp-server/contract.json" "$provenance/contract.json"
if ! python3 "$PACK" --catalog "$provenance/catalog.json" --contract "$provenance/contract.json" --output "$tmp/provenance-good" >/dev/null; then
  fail "valid catalog and contract fixture was rejected"
fi
python3 - "$provenance/contract.json" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes() + b"\n")
PY
if python3 "$PACK" --catalog "$provenance/catalog.json" --contract "$provenance/contract.json" --output "$tmp/provenance-bad-contract" >"$tmp/provenance-contract.out" 2>"$tmp/provenance-contract.err"; then
  fail "contract bytes that drift from catalog hash were accepted"
fi
cp "$ROOT/packages/mcp-server/contract.json" "$provenance/contract.json"
python3 - "$provenance/catalog.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
catalog = json.loads(path.read_text())
catalog["contract"]["contractVersion"] = "unexpected"
path.write_text(json.dumps(catalog) + "\n")
PY
if python3 "$PACK" --catalog "$provenance/catalog.json" --contract "$provenance/contract.json" --output "$tmp/provenance-bad-catalog" >"$tmp/provenance-catalog.out" 2>"$tmp/provenance-catalog.err"; then
  fail "catalog contract version drift was accepted"
fi

python3 - "$PACK" "$ROOT/packages/client/catalog.json" "$ROOT/packages/mcp-server/contract.json" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile

pack_path = pathlib.Path(sys.argv[1])
catalog_path = pathlib.Path(sys.argv[2])
source_contract = pathlib.Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("obsidian_mcp_client_pack", pack_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as directory:
    contract_path = pathlib.Path(directory) / "contract.json"
    original = source_contract.read_bytes()
    mutated = original + b"\n"
    contract_path.write_bytes(original)
    original_read_bytes = pathlib.Path.read_bytes
    contract_reads = [0]

    def read_bytes_once(path):
        if path == contract_path:
            contract_reads[0] += 1
        contents = original_read_bytes(path)
        if path == contract_path and contract_reads[0] == 1:
            contract_path.write_bytes(mutated)
        return contents

    pathlib.Path.read_bytes = read_bytes_once
    try:
        files = module.source_files(catalog_path, contract_path)
    finally:
        pathlib.Path.read_bytes = original_read_bytes

    assert contract_reads[0] == 1, contract_reads[0]
    assert files["contract.json"] == original
    manifest = json.loads(files["manifest.json"])
    assert manifest["pinnedServer"]["contractSha256"] == hashlib.sha256(original).hexdigest()
PY

python3 - "$PACK" "$ROOT/packages/client/catalog.json" "$ROOT/packages/mcp-server/contract.json" <<'PY'
import importlib.util
import json
import pathlib
import sys
import tempfile

spec = importlib.util.spec_from_file_location("catalog_snapshot_pack", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original = pathlib.Path(sys.argv[2]).read_bytes()
catalog = json.loads(original)
with tempfile.TemporaryDirectory() as directory:
    catalog_path = pathlib.Path(directory) / "catalog.json"
    catalog_path.write_bytes(original)
    changed = json.loads(original)
    changed["release"]["sourceCommit"] = "0" * 40
    changed["contract"]["commit"] = "0" * 40
    read_bytes = pathlib.Path.read_bytes
    reads = []

    def replace_after_snapshot(path):
        value = read_bytes(path)
        if path == catalog_path:
            reads.append(path)
            catalog_path.write_text(json.dumps(changed))
        return value

    pathlib.Path.read_bytes = replace_after_snapshot
    try:
        files = module.source_files(catalog_path, pathlib.Path(sys.argv[3]))
    finally:
        pathlib.Path.read_bytes = read_bytes
    manifest = json.loads(files["manifest.json"])
    assert len(reads) == 1, reads
    assert manifest["pinnedServer"]["sourceCommit"] == catalog["release"]["sourceCommit"]
    assert manifest["readBridge"] == catalog["server"]["readHttpBridge"]
PY

fake_bin="$tmp/bin"
fake_home="$tmp/home"
mkdir -p "$fake_bin" "$fake_home"

cat >"$fake_bin/npx" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$OBSIDIAN_MCP_TEST_DIR/argv"
env | LC_ALL=C sort >"$OBSIDIAN_MCP_TEST_DIR/env"
SH
chmod +x "$fake_bin/npx"
cp "$fake_bin/npx" "$fake_bin/node"

cat >"$fake_bin/security" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$OBSIDIAN_MCP_TEST_DIR/security-argv"
printf '%s' keychain-secret
SH
chmod +x "$fake_bin/security"

gnu_stat_bin="$tmp/gnu-stat-bin"
mkdir -p "$gnu_stat_bin"
cat >"$gnu_stat_bin/stat" <<'SH'
#!/bin/sh
if [ "$1" = '-f' ]; then
  printf '%s' ignored-garbage
  exit 1
fi
if [ "$1" = '-c' ] && [ "$2" = '%a' ]; then
  printf '%s' 600
  exit 0
fi
exit 64
SH
chmod +x "$gnu_stat_bin/stat"

run_profile() {
  local profile="$1" token_var="$2" token_value="$3" output="$4"
  mkdir -p "$output"
  if ! HOME="$fake_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  OBSIDIAN_MCP_TEST_DIR="$output" \
  OBSIDIAN_MCP_NPX="$fake_bin/npx" \
  OBSIDIAN_MCP_ALLOW_HTTP=1 \
  OBSIDIAN_MCP_READ_ENDPOINT='http://127.0.0.1:3010/mcp' \
  OBSIDIAN_MCP_WRITE_ENDPOINT='https://mcp.example.invalid/mcp' \
  OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=env \
  OBSIDIAN_MCP_WRITE_CREDENTIAL_PROVIDER=env \
  OBSIDIAN_MCP_READ_TOKEN_ENV=TEST_READ_TOKEN \
  OBSIDIAN_MCP_WRITE_TOKEN_ENV=TEST_WRITE_TOKEN \
  OBSIDIAN_MCP_READ_AUTHORIZATION='Bearer stale-read' \
  OBSIDIAN_MCP_WRITE_AUTHORIZATION='Bearer stale-write' \
  TEST_READ_TOKEN='read-secret' \
  TEST_WRITE_TOKEN='write-secret' \
  "$bundle/bin/obsidian-mcp-$profile" >"$output/stdout" 2>"$output/stderr"; then
    fail "$profile launcher rejected valid isolated configuration"
  fi
  return 0
}

read_output="$tmp/read"
write_output="$tmp/write"
run_profile read TEST_READ_TOKEN read-secret "$read_output"
run_profile write TEST_WRITE_TOKEN write-secret "$write_output"

read_entry="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$bundle/vendor/mcp-remote-read/mcp-remote-read.mjs")"
grep -qx "$read_entry" "$read_output/argv" || fail "read launcher bypassed the verified local bridge"
! grep -qx 'mcp-remote@0.14.3' "$read_output/argv" || fail "read launcher fell back to npx"
grep -qx 'mcp-remote@0.14.3' "$write_output/argv" || fail "write launcher changed its upstream bridge"
grep -qx 'http://127.0.0.1:3010/mcp' "$read_output/argv" || fail "read endpoint missing"
grep -qx -- '--allow-http' "$read_output/argv" || fail "explicit local HTTP was not passed through"
grep -qx -- '--preauthenticated-http' "$read_output/argv" || fail "read launcher did not select preauthenticated HTTP mode"
! grep -qx -- '--preauthenticated-http' "$write_output/argv" || fail "write launcher selected read-only preauthenticated mode"
grep -qx 'https://mcp.example.invalid/mcp' "$write_output/argv" || fail "write endpoint missing"
! grep -qx -- '--allow-http' "$write_output/argv" || fail "HTTPS launcher enabled HTTP bridge"
grep -qx 'OBSIDIAN_MCP_READ_AUTHORIZATION=Bearer read-secret' "$read_output/env" || fail "read authorization was not profile-scoped"
grep -qx 'OBSIDIAN_MCP_WRITE_AUTHORIZATION=Bearer write-secret' "$write_output/env" || fail "write authorization was not profile-scoped"
! grep -Fq 'write-secret' "$read_output/env" || fail "write token reached read child environment"
! grep -Fq 'read-secret' "$write_output/env" || fail "read token reached write child environment"
! grep -q '^TEST_READ_TOKEN=' "$read_output/env" || fail "read raw token variable reached child"
! grep -q '^TEST_WRITE_TOKEN=' "$write_output/env" || fail "write raw token variable reached child"
! grep -q '^OBSIDIAN_MCP_WRITE_AUTHORIZATION=' "$read_output/env" || fail "write authorization reached read child"
! grep -q '^OBSIDIAN_MCP_READ_AUTHORIZATION=' "$write_output/env" || fail "read authorization reached write child"
! grep -Fq 'write-secret' "$read_output/argv" || fail "write token reached read argv"
! grep -Fq 'read-secret' "$read_output/argv" || fail "read token reached argv"
! grep -Fq 'write-secret' "$write_output/argv" || fail "write token reached argv"
! grep -Fq 'read-secret' "$write_output/argv" || fail "read token reached write argv"
test ! -s "$read_output/stdout" || fail "read launcher printed output"
test ! -s "$read_output/stderr" || fail "read launcher printed output"

for scenario in missing_endpoint bad_userinfo empty_token tailnet_without_optin unknown_provider crlf_token del_token invalid_env_name invalid_opposite_env_name; do
  case "$scenario" in
    missing_endpoint) env_args=(env -u OBSIDIAN_MCP_READ_ENDPOINT) ;;
    bad_userinfo) env_args=(env OBSIDIAN_MCP_READ_ENDPOINT='https://user@example.invalid/mcp') ;;
    empty_token) mkdir -p "$tmp/$scenario"; env_args=(env TEST_READ_TOKEN=) ;;
    tailnet_without_optin) env_args=(env -u OBSIDIAN_MCP_ALLOW_HTTP OBSIDIAN_MCP_READ_ENDPOINT='http://mcp.example.ts.net/mcp') ;;
    unknown_provider) env_args=(env OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=unknown) ;;
    crlf_token) env_args=(env $'TEST_READ_TOKEN=bad\rvalue') ;;
    del_token) env_args=(env $'TEST_READ_TOKEN=bad\177value') ;;
    invalid_env_name) env_args=(env OBSIDIAN_MCP_READ_TOKEN_ENV='BAD-NAME') ;;
    invalid_opposite_env_name) env_args=(env OBSIDIAN_MCP_WRITE_TOKEN_ENV='BAD-NAME') ;;
  esac
  if HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$tmp/$scenario" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_ALLOW_HTTP=1 OBSIDIAN_MCP_READ_ENDPOINT='http://127.0.0.1:3010/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=env OBSIDIAN_MCP_READ_TOKEN_ENV=TEST_READ_TOKEN TEST_READ_TOKEN=read-secret "${env_args[@]}" "$bundle/bin/obsidian-mcp-read" >"$tmp/$scenario.out" 2>"$tmp/$scenario.err"; then
    fail "$scenario was accepted"
  fi
  ! grep -Fq 'read-secret' "$tmp/$scenario.out" "$tmp/$scenario.err" || fail "$scenario printed a secret"
  if [ "$scenario" = empty_token ]; then
    test ! -e "$tmp/$scenario/argv" || fail "empty credential started the read runtime"
  fi
done

tailnet_output="$tmp/tailnet"
mkdir -p "$tailnet_output"
HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$tailnet_output" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_ALLOW_HTTP=1 OBSIDIAN_MCP_ALLOW_TAILNET_HTTP=1 OBSIDIAN_MCP_READ_ENDPOINT='http://mcp.example.ts.net/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=env OBSIDIAN_MCP_READ_TOKEN_ENV=TEST_READ_TOKEN TEST_READ_TOKEN=read-secret "$bundle/bin/obsidian-mcp-read"
grep -qx -- '--allow-http' "$tailnet_output/argv" || fail "trusted tailnet HTTP did not opt into bridge"

tailnet_ip_output="$tmp/tailnet-ip"
mkdir -p "$tailnet_ip_output"
HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$tailnet_ip_output" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_ALLOW_HTTP=1 OBSIDIAN_MCP_ALLOW_TAILNET_HTTP=1 OBSIDIAN_MCP_READ_ENDPOINT='http://100.64.0.1:3010/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=env OBSIDIAN_MCP_READ_TOKEN_ENV=TEST_READ_TOKEN TEST_READ_TOKEN=read-secret "$bundle/bin/obsidian-mcp-read"
grep -qx 'http://100.64.0.1:3010/mcp' "$tailnet_ip_output/argv" || fail "trusted tailnet IP HTTP was rejected"

if HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$tmp/extra" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_READ_ENDPOINT='https://mcp.example.invalid/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=env OBSIDIAN_MCP_READ_TOKEN_ENV=TEST_READ_TOKEN TEST_READ_TOKEN=read-secret "$bundle/bin/obsidian-mcp-read" --header 'Authorization:override' >"$tmp/extra.out" 2>"$tmp/extra.err"; then
  fail "extra bridge arguments were accepted"
fi

file_token="$tmp/file-token"
printf '%s' file-secret >"$file_token"
if HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$tmp/file-insecure" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_READ_ENDPOINT='https://mcp.example.invalid/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=file OBSIDIAN_MCP_READ_TOKEN_FILE="$file_token" "$bundle/bin/obsidian-mcp-read" >"$tmp/file-insecure.out" 2>"$tmp/file-insecure.err"; then
  fail "world-readable file token was accepted"
fi
chmod 600 "$file_token"

legacy_bundle="$tmp/legacy-packed-client"
python3 "$PACK" --output "$legacy_bundle" >/dev/null
python3 - "$legacy_bundle/lib/launch-profile.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
current = '''  if mode="$(stat -f '%Lp' "$token_file" 2>/dev/null)"; then
    :
  elif mode="$(stat -c '%a' "$token_file" 2>/dev/null)"; then
    :
  else
    client_error
  fi
'''
legacy = '''  mode="$(stat -f '%Lp' "$token_file" 2>/dev/null || stat -c '%a' "$token_file" 2>/dev/null)" || client_error
'''
assert current in text
path.write_text(text.replace(current, legacy))
PY
if HOME="$fake_home" PATH="$gnu_stat_bin:$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$tmp/legacy-gnu-stat" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_READ_ENDPOINT='https://mcp.example.invalid/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=file OBSIDIAN_MCP_READ_TOKEN_FILE="$file_token" "$legacy_bundle/bin/obsidian-mcp-read" >"$tmp/legacy-gnu-stat.out" 2>"$tmp/legacy-gnu-stat.err"; then
  fail "legacy mixed-output stat fallback was accepted"
fi

file_output="$tmp/file"
mkdir -p "$file_output"
HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$file_output" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_READ_ENDPOINT='https://mcp.example.invalid/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=file OBSIDIAN_MCP_READ_TOKEN_FILE="$file_token" "$bundle/bin/obsidian-mcp-read"
grep -qx 'OBSIDIAN_MCP_READ_AUTHORIZATION=Bearer file-secret' "$file_output/env" || fail "file provider did not create selected authorization"
! grep -Fq 'file-secret' "$file_output/argv" || fail "file token reached argv"

gnu_stat_output="$tmp/gnu-stat"
mkdir -p "$gnu_stat_output"
HOME="$fake_home" PATH="$gnu_stat_bin:$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$gnu_stat_output" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_READ_ENDPOINT='https://mcp.example.invalid/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=file OBSIDIAN_MCP_READ_TOKEN_FILE="$file_token" "$bundle/bin/obsidian-mcp-read"
grep -qx 'OBSIDIAN_MCP_READ_AUTHORIZATION=Bearer file-secret' "$gnu_stat_output/env" || fail "GNU stat fallback did not accept a private file token"

crlf_file="$tmp/crlf-token"
printf 'bad\rvalue' >"$crlf_file"
if HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$tmp/crlf-file" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_READ_ENDPOINT='https://mcp.example.invalid/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=file OBSIDIAN_MCP_READ_TOKEN_FILE="$crlf_file" "$bundle/bin/obsidian-mcp-read" >"$tmp/crlf-file.out" 2>"$tmp/crlf-file.err"; then
  fail "CRLF file token was accepted"
fi

keychain_output="$tmp/keychain"
mkdir -p "$keychain_output"
HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$keychain_output" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_WRITE_ENDPOINT='https://mcp.example.invalid/mcp' OBSIDIAN_MCP_WRITE_CREDENTIAL_PROVIDER=keychain OBSIDIAN_MCP_WRITE_KEYCHAIN_SERVICE=example-service OBSIDIAN_MCP_WRITE_KEYCHAIN_ACCOUNT=example-account "$bundle/bin/obsidian-mcp-write"
grep -qx 'OBSIDIAN_MCP_WRITE_AUTHORIZATION=Bearer keychain-secret' "$keychain_output/env" || fail "keychain provider did not create selected authorization"
grep -qx -- '-a' "$keychain_output/security-argv" || fail "keychain account argument missing"
! grep -Fq 'keychain-secret' "$keychain_output/argv" || fail "keychain token reached argv"

for scenario in missing_bridge changed_bridge changed_provenance nonexecutable_helper symlinked_vendor unexpected_symlink; do
  broken="$tmp/$scenario-bundle"
  python3 "$PACK" --output "$broken" >/dev/null
  case "$scenario" in
    missing_bridge) mv "$broken/vendor/mcp-remote-read/mcp-remote-read.mjs" "$broken/vendor/mcp-remote-read/mcp-remote-read.mjs.saved" ;;
    changed_bridge) printf '\n' >> "$broken/vendor/mcp-remote-read/mcp-remote-read.mjs" ;;
    changed_provenance) printf '\n' >> "$broken/vendor/mcp-remote-read/provenance.json" ;;
    nonexecutable_helper) chmod 644 "$broken/vendor/mcp-remote-read/xdg-open" ;;
    symlinked_vendor) mv "$broken/vendor" "$broken/vendor-real"; ln -s vendor-real "$broken/vendor" ;;
    unexpected_symlink) ln -s . "$broken/vendor/mcp-remote-read/extra-directory" ;;
  esac
  output="$tmp/$scenario-launch"
  mkdir -p "$output"
  if HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin" OBSIDIAN_MCP_TEST_DIR="$output" OBSIDIAN_MCP_NPX="$fake_bin/npx" OBSIDIAN_MCP_READ_ENDPOINT='https://mcp.example.invalid/mcp' OBSIDIAN_MCP_READ_CREDENTIAL_PROVIDER=env OBSIDIAN_MCP_READ_TOKEN_ENV=TEST_READ_TOKEN TEST_READ_TOKEN=read-secret "$broken/bin/obsidian-mcp-read" >"$output/stdout" 2>"$output/stderr"; then
    fail "$scenario executed an unverified bridge"
  fi
  test ! -e "$output/argv" || fail "$scenario reached a bridge process"
  ! grep -Fq 'read-secret' "$output/stdout" "$output/stderr" || fail "$scenario printed a credential"
done

extra_bundle="$tmp/unexpected-output-symlink"
python3 "$PACK" --output "$extra_bundle" >/dev/null
ln -s vendor "$extra_bundle/extra-directory"
if python3 "$PACK" --output "$extra_bundle" >"$tmp/extra-directory.out" 2>"$tmp/extra-directory.err"; then
  fail "existing bundle accepted an unallowlisted symlink directory"
fi

hardlinked_output="$tmp/hardlinked-output"
python3 "$PACK" --output "$hardlinked_output" >/dev/null
mv "$hardlinked_output/README.md" "$tmp/hardlinked-output-readme"
ln "$tmp/hardlinked-output-readme" "$hardlinked_output/README.md"
if python3 "$PACK" --output "$hardlinked_output" >"$tmp/hardlinked-output.out" 2>"$tmp/hardlinked-output.err"; then
  fail "existing bundle accepted a hard-linked file"
fi

python3 - "$PACK" "$ROOT/packages/client" <<'PY'
import importlib.util
import os
import pathlib
import shutil
import sys
import tempfile

spec = importlib.util.spec_from_file_location("hardlink_source_pack", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    source = pathlib.Path(directory) / "client"
    shutil.copytree(sys.argv[2], source)
    readme = source / "README.md"
    saved = pathlib.Path(directory) / "README.saved"
    readme.rename(saved)
    os.link(saved, readme)
    module.SOURCE = source
    try:
        module.source_files(module.CATALOG, module.CONTRACT)
    except ValueError as error:
        assert "private regular file" in str(error), error
    else:
        raise AssertionError("packer accepted a hard-linked source file")
PY

python3 - "$PACK" "$ROOT/packages/client" <<'PY'
import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile

spec = importlib.util.spec_from_file_location("capture_defaults_pack", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    for name, value in (("true", True), ("zero", 0), ("null", None), ("omitted", "omitted")):
        source = pathlib.Path(directory) / name
        shutil.copytree(sys.argv[2], source)
        manifest_path = source / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        if value == "omitted":
            del manifest["commitCapture"]["defaultActivated"]
        else:
            manifest["commitCapture"]["defaultActivated"] = value
        manifest_path.write_text(json.dumps(manifest) + "\n")
        module.SOURCE = source
        files = module.source_files(module.CATALOG, module.CONTRACT)
        try:
            module.release_metadata(files)
        except ValueError as error:
            assert "literal false" in str(error), error
        else:
            raise AssertionError(f"release metadata accepted {name} capture default")
PY

python3 - "$PACK" "$bundle" <<'PY'
import importlib.util
import pathlib
import sys
import tempfile

spec = importlib.util.spec_from_file_location("read_bridge_pack", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    module.SOURCE = pathlib.Path(sys.argv[2])
    path = module.SOURCE / "vendor/mcp-remote-read/mcp-remote-read.mjs"
    original = path.read_bytes()
    path.write_bytes(original + b"\n")
    try:
        try:
            module.source_files(module.CATALOG, module.CONTRACT)
        except ValueError:
            pass
        else:
            raise AssertionError("packer accepted changed runtime bytes")
    finally:
        path.write_bytes(original)
PY

grep -Fq 'plugin-free' "$bundle/README.md" || fail "README does not state client boundary"
grep -Fq "The default pin is \`mcp-v0.2.0\`" "$bundle/README.md" || fail "README does not name the pinned release"
grep -Fq "\`mcp-v0.2.0\` provides exact-target append" "$bundle/README.md" || fail "README capability wording does not match the pinned release"
grep -Fq 'live server version and discovered schema to match' "$bundle/README.md" || fail "README does not preserve the live capability gate"
! grep -R -E '/Users/|100\.[0-9]+\.|obsidian-mcp-read-token' "$bundle" >/dev/null || fail "packed bundle contains a personal path, endpoint, or credential service"

OBSIDIAN_MCP_TEST_READ_LAUNCHER="$bundle/bin/obsidian-mcp-read" \
  node "$ROOT/tests/obsidian-mcp-read-bridge.test.mjs"

for mutation in captured-session read-allowlist clear-session preauthenticated-http unresolved-bearer unresolved-header unresolved-header-nonpreauth first-authorization-only unresolved-client-info; do
  case "$mutation" in
    captured-session) expected='late old-session 404 triggered an extra reinitialization' ;;
    read-allowlist) expected='nonallowlisted write was replayed' ;;
    clear-session) expected='pre-header recovery failed' ;;
    preauthenticated-http) expected='preauthenticated startup probed OAuth metadata|rejected credential triggered metadata discovery' ;;
    unresolved-bearer) expected='invalid preauthenticated startup succeeded' ;;
    unresolved-header) expected='invalid preauthenticated startup succeeded' ;;
    unresolved-header-nonpreauth) expected='invalid non-preauthenticated startup succeeded' ;;
    first-authorization-only) expected='invalid preauthenticated startup succeeded' ;;
    unresolved-client-info) expected='invalid non-preauthenticated startup (succeeded|reached the network)' ;;
  esac
  if node "$ROOT/tests/obsidian-mcp-read-bridge.test.mjs" "$mutation" >"$tmp/$mutation.out" 2>&1; then
    fail "$mutation regression survived"
  fi
  grep -Eq "$expected" "$tmp/$mutation.out" || fail "$mutation failed outside its regression assertion"
done

printf 'PASS obsidian MCP client bundle\n'
