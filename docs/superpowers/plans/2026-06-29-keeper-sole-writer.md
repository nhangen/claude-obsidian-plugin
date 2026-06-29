# Keeper as Sole Writer — Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Funnel save-conversation's writes through the keeper, non-disruptively,
by adding an opt-in pre-resolved mode to the keeper's INSERT.

**Architecture:** Additive opt-in seam. The keeper's INSERT gains
`folder_hint`-authoritative + `resolved: true` semantics; callers that pass
neither are unchanged. save-conversation keeps all cognition and swaps only its
direct disk writes for keeper-save calls.

**Tech Stack:** Bash payload lib (dependency-free), markdown skill/agent prose,
shell test harness (`tests/run-all.sh`).

## Global Constraints

- The keeper change MUST be additive: an INSERT payload with no `folder_hint`
  and no `resolved` behaves exactly as today (routes + dedups).
- `resolved` is enabled ONLY by the literal `true`; absent/any-other-value =
  full keeper routing. No silent coercion.
- save-conversation keeps inference, routing, same-day dedup, MOC, substrate,
  and segmentation. Only `Write`/`Edit`/`mkdir` calls move to the keeper.
- Every behavior change has a test that fails when the change is reverted.
- No commit until `tests/run-all.sh` is green. Personal repo — push allowed.

---

### Task 1: Keeper INSERT pre-resolved mode

**Files:**
- Modify: `scripts/lib/keeper-save-payload.sh` (accept `resolved` field; no new
  required-field rules — INSERT still needs title+body)
- Modify: `agents/vault-librarian.md` (§INSERT: folder_hint authoritative;
  `resolved` skips routing + dedup)
- Modify: `skills/keeper-save/SKILL.md` (document `resolved` + folder_hint
  authority in payload format and Step 4 INSERT)
- Test: `tests/keeper-save-payload.sh`, `tests/vault-librarian-agent.sh`

**Interfaces:**
- Produces: payload field `resolved` (optional, `true`|absent). `folder_hint`
  already exists; its meaning tightens to "authoritative target when present."

- [ ] **Step 1: Failing test — payload accepts a pre-resolved INSERT.**
  Add to `tests/keeper-save-payload.sh`:
  ```bash
  cat > "$TMP/resolved.md" <<'EOF'
  op: insert
  resolved: true
  title: Pre-resolved note
  folder_hint: Projects/Development/nhangen/foo
  ---
  body
  EOF
  kspayload_validate "$TMP/resolved.md" || fail "pre-resolved insert should pass"
  [ "$(kspayload_field "$TMP/resolved.md" resolved)" = "true" ] || fail "resolved field parse"
  [ "$(kspayload_field "$TMP/resolved.md" folder_hint)" = "Projects/Development/nhangen/foo" ] || fail "folder_hint parse"
  ```

- [ ] **Step 2: Run — expect the resolved-field parse assertion to pass already**
  (`kspayload_field` is generic), and `kspayload_validate` to pass (insert with
  title+body). Run: `bash tests/keeper-save-payload.sh`. If it already passes,
  the lib needs no code change — the field is generic. Confirm, then proceed to
  the prose (the behavior lives in the agent, not the lib).

- [ ] **Step 3: Librarian §INSERT — resolved is the SOLE skip trigger.**
  Edit `agents/vault-librarian.md` §INSERT step 1 to: "If `resolved: true`, the
  caller already owns routing and dedup — write to `folder_hint` as-is, do not
  run routing, and skip the dedup scan (step 2). Otherwise route as below;
  `folder_hint` is a hint only (unchanged behavior)." This gates the skip on
  `resolved`, NOT on `folder_hint` presence — `hari-seldon`/`create-note` pass
  `folder_hint` today and must keep getting routed + deduped. Keep template +
  INDEX-link + Pending behavior.

- [ ] **Step 4: keeper-save SKILL.md — document the seam.**
  Add `resolved: <optional — true: caller already routed+deduped; keeper writes
  to folder_hint as-is>` to the payload format block, and a sentence in Step 4
  INSERT that folder_hint is authoritative and `resolved: true` skips keeper
  dedup.

- [ ] **Step 5: Librarian-agent test asserts the seam SEMANTICS (mutation-safe).**
  Add to `tests/vault-librarian-agent.sh` — phrases that encode the gate, so
  gutting the clause fails the test (not a bare-word grep):
  ```bash
  need "resolved: true"           # the literal trigger
  need "do not run routing"       # routing skip is gated on resolved
  need "skip the dedup scan"      # dedup skip is gated on resolved
  ```
  Mutation check: delete the `resolved` clause from the agent → these `need`s
  fail.

- [ ] **Step 6: Run full suite, commit.**
  Run: `bash tests/run-all.sh` → ALL PASS. Commit (no version bump yet; bundle
  with Task 2's bump).

---

### Task 2: save-conversation funnels writes through the keeper

**Files:**
- Modify: `skills/save-conversation/SKILL.md` (steps 11–12 new-file write →
  keeper-save INSERT resolved; same-day append → keeper-save APPEND; substrate
  object create → keeper-save INSERT resolved)
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
  `~/ML-AI/claude/plugins/.claude-plugin/marketplace.json` (bump 1.12.0 → 1.13.0)

**Interfaces:**
- Consumes: keeper-save INSERT (`resolved`, `folder_hint`) + APPEND (`target`,
  `section`, `body`) from Task 1 and the existing APPEND.

- [ ] **Step 1: New-file write → keeper-save INSERT.**
  In `skills/save-conversation/SKILL.md` step 12, replace the direct `Write`
  with: invoke `obsidian:keeper-save` with `op: insert`, `resolved: true`,
  `folder_hint: <resolved target folder from step 5>`, `title`/body = the built
  note, `links`. Keep steps 1–11 (inference, routing, dedup, allow-list, MOC
  detection) unchanged — they are the pre-step that produces the resolved
  folder. Relay the keeper's returned path.

- [ ] **Step 2: Same-day-twin append → keeper-save APPEND.**
  In the Same-Day Dedup Check "Append mode" (skill lines ~249–253), replace the
  direct `Edit` with: invoke `obsidian:keeper-save` with `op: append`,
  `target: <the twin file>`, `section: ## HH:MM — <Title>`, `body: <the FULL h3
  sub-block structure>`. The librarian writes `body` verbatim and will not
  reconstruct the h3 nesting, so save-conversation builds the complete
  `### Summary` / `### Key Findings` / `### Details` / `### Related` block and
  passes it as `body`. The twin already exists so create-on-absent never fires;
  no-INDEX is acceptable (file-level INDEX, twin already indexed, section not
  separately tracked).

- [ ] **Step 3: Substrate object → explicit dedup, then keeper-save INSERT.**
  Where the skill creates a Research-Substrate object (lines ~94–101): first add
  an explicit dedup pre-step — scan `Research-Substrate/<type>` for an existing
  object on the same claim/slug and update it instead of creating a twin. Then
  file the create/update via `obsidian:keeper-save` INSERT (`resolved: true`,
  `folder_hint: Projects/Physics-AI-ML/Research-Substrate/<type>`). The pre-step
  is required because `resolved: true` skips the keeper's dedup and
  save-conversation otherwise has none for substrate. Linking from the session
  note is unchanged.

- [ ] **Step 4: Note what stays native.**
  Add a short note under the skill's header: MOC-promotion file *moves* stay
  native (vault-organizer territory); only note-writes funnel through the
  keeper. Bump skill `version` to 1.1.0.

- [ ] **Step 5: Version bump + full suite + commit + publish.**
  Bump the three manifests to 1.13.0. Run `bash tests/run-all.sh` → ALL PASS.
  Commit, push obsidian-plugin + marketplace, refresh marketplace clone, and
  `claude plugin update obsidian@nhangen-tools`.

## Verification

- `tests/run-all.sh` green after each task.
- Mutation check Task 1: revert the librarian "folder_hint authoritative" clause
  → `tests/vault-librarian-agent.sh` fails on the missing `need` string.
- save-conversation is prose; verify by reading that no `Write`/`Edit`/`mkdir`
  of a *note* remains in steps 12 / append-mode / substrate (MOC moves excepted).
