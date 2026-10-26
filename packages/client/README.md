# Obsidian MCP portable client

This plugin-free client bundle connects to the catalog-pinned server release through separate read and write Streamable HTTP profiles. It does not require an Obsidian vault mount or an installed Obsidian plugin on the client.

The profile `requiredScopes` describe which token each profile needs. They do not limit a credential themselves; the server enforces the actual request scopes.

Configure each profile explicitly with environment variables. `OBSIDIAN_MCP_<PROFILE>_CREDENTIAL_PROVIDER` accepts `env`, `file`, or `keychain`; see [`examples/profiles.env.example`](examples/profiles.env.example). The selected token is exported only to the child bridge process as a profile-specific authorization variable. It is never written to a temporary file or passed as a command-line argument. File credentials must be owned by the invoking user and mode `0400` or `0600`.

`https` endpoints are accepted by default. Loopback `http` requires `OBSIDIAN_MCP_ALLOW_HTTP=1`; a `.ts.net` HTTP endpoint additionally requires `OBSIDIAN_MCP_ALLOW_TAILNET_HTTP=1`. URL userinfo and control characters are rejected. `Origin` is derived from the endpoint authority unless `OBSIDIAN_MCP_<PROFILE>_ORIGIN` supplies a valid explicit origin.

Use a host's documented native Streamable HTTP MCP registration when it supports that transport. This bundle intentionally does not invent host-specific configuration or approval syntax. The read launcher verifies the bundled `mcp-remote@0.14.3` derivative before executing it with Node.js. Its dedicated preauthenticated HTTP mode requires the launcher's explicit bearer header, skips OAuth discovery and compatibility probing, and fails closed on authorization errors without starting an OAuth flow. Only `obsidian_find_notes` retries once after an expired-session HTTP 404, sharing recovery across concurrent reads. Session-expiry recovery excludes writes, authentication failures and timeouts. Missing or mismatched artifact bytes fail closed without an npm-cache fallback. The upstream license, source hashes and exact patch are included under `vendor/mcp-remote-read`.

The read runtime is self-contained: it needs no installed `node_modules` or npm cache. Its pinned build lock, rebuild script, patch, licenses, and Linux `xdg-open` helper are included and verified with the bundle. The write launcher remains on unmodified `mcp-remote@0.14.3` through `npx` from `PATH`, or an executable path in `OBSIDIAN_MCP_NPX`. It never loads the patched read runtime. The bundle requires Python 3 and Node.js 22 or newer; pack an immutable output with `python3 scripts/pack-obsidian-mcp-client.py --output <directory>`. A different bundle needs a different directory; packing never overwrites an existing mismatched bundle.

The packer emits `release.json` and prints its SHA-256. Obtain both the standalone
`bin/obsidian-mcp-client-install` bootstrap and that expected digest from a trusted
build or an outer authenticated release. The installer checks the exact bounded
metadata bytes against the externally supplied digest before parsing them, then
checks every payload path, mode, digest, and release identity. The copy of the
installer listed in its own inventory is diagnostic evidence after trust has been
established; it cannot authenticate itself.

Client-owned failures use exit code `64` consistently in the installer, packer,
commit-event producer, commit-capture consumer, and read/write launchers. This
includes invalid CLI arguments; `--help` on the installer and packer remains a
successful exit. A launched third-party bridge retains its own exit status.
If packing fails after creating the output directory, the error names the
incomplete directory to inspect and remove before retrying; it is not overwritten
or silently deleted.

Install with `python3 bin/obsidian-mcp-client-install --bundle <bundle>
--release-sha256 <digest>`. `--dry-run` makes no managed-directory changes. Releases
are immutable and retained under `<prefix>/releases/<release-id>`; `current`,
`previous`, and `disabled` are the only completed-state pointers. Upgrades and
`--rollback` keep the client enabled or disabled as it was; `--disable` and
`--enable` switch it. A locked,
fsynced transition journal recognizes only its complete before, after, and canonical
partial pointer maps. Unknown state fails closed. Reinstalling the same verified
release does not replace its files. No operation changes host configuration,
credentials, hooks, vault content, server state, or writer ownership.

`--prefix` accepts absolute paths or paths relative to the current working
directory, normalizing `~`, `.` and `..` before applying the same safety checks.
Dry runs print one canonical JSON object with `after`, `before`, `dryRun`, and
`operation`, with release IDs or `null` in the three slot fields. An interrupted
release copy cannot activate a partial release. Abandoned `.release-*` staging
directories are not reused; a cleanup failure reports the exact path without
hiding the original failure. Existing incomplete or tampered `releases/<id>`
directories fail closed instead of being overwritten.

The home wrapper still defaults to the separately packed `read-bridge-v1`. To test
or canary an installed release explicitly, set
`OBSIDIAN_MCP_READ_CLIENT_DIR=<prefix>/current`. Default activation is intentionally
outside this lifecycle change.

The bundle includes a commit-capture consumer. The default pinned release
`mcp-v0.2.0` provides exact-target append and the exact/prefix hash guard, so an
explicit invocation can pass the local capability gate. The consumer still requires
the live server version and discovered schema to match before writing; the released
contract alone does not change writer ownership.

## Local commit-event metadata

`bin/obsidian-mcp-commit-event` requires a POSIX host (macOS, Linux or WSL), Python
3 and Git. It reads one JSON event
from stdin after a host has observed a successful commit:

```json
{"schemaVersion":1,"event":"git.commit","outcome":"success","repository":"/absolute/repository/root","commit":"0123456789012345678901234567890123456789"}
```

The host must supply the full commit hash from that event, not a revision expression.
The producer requires that commit to remain HEAD in the exact repository root.
Missing, failed, stale or malformed events return a nonzero exit with a bounded
diagnostic and no metadata. An event is a trusted host assertion, not proof the
producer executed the commit. Do not invoke it on failed commands or infer an event
from an arbitrary existing HEAD.

Input is capped at 64 KiB with a five-second read deadline. Each read-only Git
command has a five-second deadline and capped output; a stalled command's process
group is terminated. Limits fail explicitly rather than truncating metadata.

The JSON result contains the full hash, current branch, changed files, sanitized
`org_repo` and `repo_name`, branch ticket, and commit-local date/time. Detached HEAD
has an empty branch; a repository without origin uses `local/<repository-name>`.
Transport credentials and URL query/fragment data never enter repository identity.
No vault path, plugin configuration, author identity or commit subject is emitted.

This is a read-only metadata producer, not a capture hook or a vault writer. It
does not install hooks, change MCP routing, or report a commit as captured. Hosts
without a successful-event channel must report that capability as unavailable.

## Commit capture consumer

`bin/obsidian-mcp-capture-commit` accepts the same five event fields plus a
required `context` array of one to eight single-line, client-authored summary
items. It invokes the bundled event producer locally, then appends through the
bundled write bridge only after both the bundled contract and live discovered
`obsidian_daily_append` schema expose `target_path`, `skip_if_hash`, `section`,
and `idempotency_key`. The client requests `2025-11-25` only when the pinned
matrix approves that implemented initialize revision for both stdio and Streamable
HTTP with non-planned status. The initialize response must return that exact
protocol, an initialized tools capability object, and the server version pinned by
the manifest before the client sends any initialized notification or tool request.

The default target is
`Projects/Development/<org>/<repo>/<date>.md`. The retained `mtf-builder`
override writes `Altamira/mtf-builder/commits/<date>-mtf-builder-commits.md`.
The section includes commit-local time and the full hash; the body includes the
branch and supplied context. A deterministic idempotency key is derived from the
sanitized repository identity and full commit hash, so changed context under the
same commit is a server conflict rather than a second write.

The consumer reports JSON with `status: committed` only after validating a
non-error, non-recoverable committed outcome at the exact target. An exact replay
is reported as `status: skipped`. Partial, conflicted, contradictory, mismatched,
or unknown outcomes exit nonzero without claiming capture. Validated partial,
conflict, and failed outcomes emit a bounded JSON failure envelope containing the
stable idempotency key, canonical path, affected paths, status, error code,
retryability, recovery requirement, and fixed client guidance. An unknown result
after dispatch is `ambiguous` and requires authoritative-path verification before
retrying with the same key. Arbitrary server strings, bridge stderr, and request
content are never copied into diagnostics.
An idempotency-key conflict directs the operator to verify the existing idempotency
record. A heading-identity conflict instead directs the operator to verify the note's
full commit identity.

The bridge operation budget defaults to 120 seconds across initialization, tool
discovery, and the remote append. `OBSIDIAN_MCP_CAPTURE_BRIDGE_TIMEOUT_SECONDS`
may set an integer from 1 through 300 for isolated environments. Invalid values
fail before the bridge starts. The producer and bridge pipes retain independent
size and deadline bounds. Successful shutdown closes stdin and waits through the
grace period before reaping any surviving process-group descendants.

This CLI does not install a Git hook, claim writer ownership, change host routing,
or fall back to the plugin keeper.

The consumer remains default-unactivated. On an upgraded server, exact full hashes
skip and a strict short/full prefix relation blocks with `CONFLICT`; no arbitrary
historical alias is treated as equivalent and the bundle performs no historical
backfill. Old server releases and rollback to a pre-upgrade writer are unsupported
for this migration. The default pin is `mcp-v0.2.0`, but
`legacyHashInteroperability` remains `unproven` and capture remains disabled by
default until the live canary and writer-ownership migration complete.

## Native capture in an isolated Codex profile

The bundle includes a first-host integration for Codex native hooks. It requires
a POSIX client, Python 3.11+, a Codex build supporting UserPromptSubmit,
PreToolUse/PostToolUse and Stop hooks, a new CODEX_HOME, and a clean Git project
with no inherited `.codex`, `.claude`, `.opencode`, `.agents`, AGENTS.md or CLAUDE.md.
Codex 0.163.0 exposes these hooks. This is an opt-in profile, not migration of an
existing host or completion of the other-host matrix.

Configure the read/write endpoint and credential-reference environment variables
from `examples/profiles.env.example`, then create the profile using the trusted
packed bundle's external release.json digest:

```sh
<bundle>/bin/obsidian-mcp-native create --home /absolute/new-codex-home \
  --project /absolute/clean-git-project --folder Projects/Development/example/project \
  --release-sha256 <trusted-digest>
<bundle>/bin/obsidian-mcp-native run --home /absolute/new-codex-home
```

Authenticate Codex in that isolated profile separately. No provider credentials
are copied from another profile. The launcher fixes CODEX_HOME and cwd; config
registers only the two MCP launchers, native capture hooks, and scoped automatic
MCP approval. Endpoint credential values are not serialized into profile files.
Creation returns `launch_command` with the absolute creator Python interpreter.
Use that command when the shell PATH differs; hooks, executor and capture guidance
pin the same Python 3.11+ interpreter. Recreate the profile if it is removed.
Only selected environment variable names are forwarded to the MCP children.
On macOS the isolated HOME has no default keychain search list. Supply credentials
through the existing environment provider or an absolute private credential file.
The launcher also isolates HOME and XDG directories under `runtime-home`, so
personal `.agents/skills` and user configuration are not silently inherited.
Open `/hooks` in that profile and review/trust the exact hook definitions before
using capture. Untrusted hooks are skipped by Codex; profile creation is not hook
activation. No hook-trust bypass is installed. The workspace-write sandbox grants
the local helper write access only to this profile's capture-state directory.
Codex may add UI, project-trust and hook-trust records to its config. The helper
accepts those host records while requiring the capture configuration to match.

UserPromptSubmit establishes a turn-bound session-save identity. The current host
model supplies the meaningful summary and invokes the native MCP save tool.
PostToolUse validates its successful receipt, including note, INDEX and daily
paths. An explicit turn-bound `skip` records `skipped_by_policy`, not a saved note.
Stop requests one continuation without a receipt; a repeated Stop reports
unresolved capture instead of looping or claiming success. Pending previous work
cannot be silently discarded by the next user prompt.

For commits, run one `git -C <project> commit ...` command, optionally with `rtk`
or `rtk proxy`; stage and test in separate tool calls. The paired hooks require a
matching call ID/command, a successful executor result, and exactly one local reflog
commit transition. Compound commands, substitutions, redirects and environment
overrides are explicitly unsupported. No event means no inferred historical tip.
The existing producer sanitizes metadata; `prepare` takes the pending event ID and
model-supplied context, then reuses the consumer's canonical argument builder.
The model calls the native MCP append tool with those exact prepared arguments.
Codex sends raw shell output to PostToolUse without an exit envelope. PreToolUse
therefore rewrites eligible commits through the bundled local executor, retaining
the original validated arguments. The executor records its actual Git exit code
and verified transition privately before PostToolUse consumes them; printed text
cannot substitute for that record. Normal sandbox approval applies to the rewritten
command. The hook permits and rewrites only supported commits; Codex still applies
its configured sandbox and normal execution-approval policy. Interrupted execution
remains unresolved for explicit inspection, and a
completed executor record cannot execute Git a second time.
Pre/Post hooks require matching call IDs, arguments and validated receipts.
No second shell-based network or approval path is introduced.
Commit capture is serialized at project scope. The session that prepares an
eligible commit owns the capture window: while one of its executor snapshots or
pending commit events is unresolved, the hooks deny other sessions in the same
profile new commit tool calls instead of letting them advance HEAD and strand
the earlier capture. External Git processes outside the hooks bypass this gate
and will still leave the earlier capture unresolved. `status --home <profile>
--session <key>` reports `gate` naming the owning session when denial applies.
An interrupted owner is recoverable: `takeover --home <profile> --session
<your-key> --verification command-stopped-and-history-inspected` records the
owner's snapshots and pending commits as `not_captured` evidence, releases the
gate, and never claims a successful capture or reconstructs git history. An
owner with nothing pending reports `recovered_no_pending` instead of
`recovered`, an owner whose state file is missing reports
`recovered_owner_state_missing` (nothing was inspected), and a failed
`git rev-parse` marks the record's `observed_head` null with `head_unavailable`
in the result. A write the owner had already dispatched may still land later; the rescued event stays
marked unresolved, which under-reports rather than over-reports capture.
If `capture-state/active.json` is corrupt (`ACTIVE_STATE_INVALID`), the same `takeover`
command deletes it and reports `cleared_invalid_gate`; the commit event is already
recorded in the session state by then. `takeover` also aborts with
`INTERRUPTED_OWNERSHIP_CHANGED` if the owner released the gate while it waited.
If `daily-append` or `resolve-snapshot` finish their local write and then find
the gate corrupt or owned by another session, they report it (`note` in the
result, one context line in the hook) without raising, so a completed capture
is not reported as a failed operation.
Cross-session repair details and follow-ups remain tracked for separate multi-session workflows.
The full commit must still be HEAD. Replays preserve the original payload digest;
changed context conflicts locally. Partial/unknown outcomes remain visible and
block automatic retry until manually inspected. `retry --session <key> --commit
<event-id> --payload-sha256 <digest-from-status> --verification
authoritative-path-inspected` records that explicit verification and returns the
original native append arguments; omit `--commit` for original session-save
arguments. The helper does not claim to have performed the authoritative
inspection. `request --session <key>` explicitly prints the preserved session
payload for exact retry; ordinary status omits saved content. A changed payload is
never a recovery action. Do not review/retry a native call that is still running.
For a denied/canceled commit tool with no Post event, first confirm the tool stopped
and inspect local history, then use `resolve-snapshot --session <key> --snapshot
<id> --verification command-stopped-and-history-inspected`. This retains explicit
`not_captured` evidence and never reconstructs a missing successful event.

Use `status --home <profile> --session <key-from-hook>` to inspect bounded local
evidence without a vault mount. `disable --home <profile>` verifies the owned files
and removes only the profile's config, hooks and instructions, retaining auth and
capture evidence. Drift refuses disable. Existing profiles/plugins, Git hooks,
vault content and running sessions are never changed. Restart or close a running
profile before disabling it; an already-running host has loaded its hook settings.
General profile upgrade/migration and an all-host writer handoff remain separate
acceptance gates. The existing managed client installer still owns bundle lifecycle.
