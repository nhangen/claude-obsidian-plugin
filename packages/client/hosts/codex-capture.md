# Native Obsidian capture

This isolated Codex profile owns session and commit capture through MCP. Do not
invoke plugin keeper, plugin hooks, local vault scripts or private harness rules.
The configured `obsidian` and `obsidian-write` servers are the only vault routes.
Routine writes use the scoped automatic host policy already configured.

Native UserPromptSubmit supplies a turn-specific save identity. Preserve it and
save meaningful work at the end of the turn with the requested keeper arguments,
including session_link_date. Write a factual summary of goal, findings, decisions,
changes, validation environment and loose ends. Read-only research can be meaningful.
For a trivial acknowledgement or explicit no-capture request, use the provided
turn-bound skip command. A policy skip is not a saved note.

Run commits as one `git -C <project-root> commit ...` command, optionally prefixed
with `rtk` or `rtk proxy`; stage and test in separate calls. Compound commands,
substitutions and redirects are unsupported for native commit capture. The native
PreToolUse rewrites eligible commits through the bundled local executor, which
records the real Git exit code and transition. Normal sandbox approval still
applies. Pre/Post hooks establish a successful event and deliver a pending commit ID.
Immediately pass factual conversation context to the supplied `prepare` command,
then call the native MCP append tool with its exact returned arguments.
Never fabricate an event, infer a hash after a missing event, or read a raw remote
URL to construct capture metadata. A pending event whose commit is no longer HEAD
must be reported unresolved; do not create a new key to bypass that failure.

Only committed/skipped validated MCP receipts establish successful capture.
Inspect partial outcomes and recovery.required before retrying. Keep identical
payloads and keys for exact retry; conflicts require inspection. Hook instructions
and Stop continuations are not write receipts. Report unresolved capture honestly.
Status omits saved content. `request` explicitly retrieves the original session
payload. After inspecting authoritative paths, `retry` with the recorded payload
digest and verification flag returns only the original arguments for native MCP
retry. It does not itself verify the vault or mark a write successful.
Another session in the same profile may be denied while this profile owns an
unresolved commit capture; wait until it resolves, or rescue an interrupted owner
only after inspecting it, using the takeover command the denial names.

This profile requires a clean project without inherited agent settings or capture
instructions. It does not disable another session or migrate an existing profile.
Other supported-host projections and plugin ownership migration remain separate
follow-up acceptance gates.
