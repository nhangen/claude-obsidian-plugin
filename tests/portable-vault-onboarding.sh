#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${PORTABLE_TEST_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

test_summarizer_prompt_uses_configured_taxonomy() {
  local case_dir
  case_dir="$(mktemp -d "${TMPDIR:-/tmp}/obsidian-portable-vault-XXXXXX")" || return 1
  trap 'rm -rf "$case_dir"; trap - RETURN' RETURN
  mkdir -p "$case_dir/home" "$case_dir/bin" "$case_dir/tmp" "$case_dir/vault"

  cat > "$case_dir/config.md" <<EOF
---
vault_path: $case_dir/vault
daily_path: Journal/
---

## Project Taxonomy

| Domain | Vault path | Notes |
|--------|------------|-------|
| Marine | Projects/Marine-Systems/ | Field research |
| Daily | Journal/ | Daily notes |
| Inbox | Inbox/ | Fallback |

## Routing Rules

- Keywords "reef, vessel, survey" -> Projects/Marine-Systems/
- Ambiguous -> Inbox/
EOF
  printf '%s\n' '{"type":"user","message":{"content":"Summarize the reef survey findings."}}' > "$case_dir/transcript.jsonl"
  cat > "$case_dir/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt=""
print_seen=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print) print_seen=true; shift ;;
    --bare|--no-session-persistence|--disable-slash-commands|--strict-mcp-config) shift ;;
    --tools|--setting-sources)
      [ "$#" -ge 2 ] && [ -z "$2" ] || exit 99
      shift 2
      ;;
    --system-prompt)
      [ "$#" -ge 2 ] && [ -n "$2" ] || exit 99
      prompt="$2"
      shift 2
      ;;
    --model|--effort|--output-format|--settings) shift 2 ;;
    --max-budget-usd)
      [ "$#" -ge 2 ] && [ "$2" = "0.10" ] || exit 99
      shift 2
      ;;
    *) printf 'stub: unexpected claude argv\n' >&2; exit 99 ;;
  esac
done
[ "$print_seen" = true ] && [ -n "$prompt" ] || exit 99
printf '%s' "$prompt" > "${PROMPT_CAPTURE:?}"
cat >/dev/null
python3 -c 'import json,sys; print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":sys.stdin.read()}))' <<'NOTE'
---
vault_folder: Projects/Marine-Systems/
slug: reef-survey
session_intent: research
capture_action: project_note
research_state_change: new_evidence
substrate_object: ""
---

# Reef Survey

Research findings remain in the configured project when no separate research destination exists.
NOTE
EOF
  chmod +x "$case_dir/bin/claude"

  HOME="$case_dir/home" \
    TMPDIR="$case_dir/tmp" \
    OBSIDIAN_LOCAL_MD="$case_dir/config.md" \
    PATH="$case_dir/bin:$PATH" \
    PROMPT_CAPTURE="$case_dir/prompt.txt" \
    bash "$ROOT_DIR/scripts/session-summarize.sh" \
      "$case_dir/transcript.jsonl" "$case_dir/config.md" "$case_dir/vault" \
    || { fail 'production session summarizer failed before prompt assertions'; return 1; }

  [ -f "$case_dir/prompt.txt" ] \
    || { fail 'model boundary did not capture the production prompt'; return 1; }
  grep -qF 'Projects/Marine-Systems/' "$case_dir/prompt.txt" \
    || { fail 'configured Marine taxonomy is absent from the production prompt'; return 1; }
  if grep -qF 'Projects/Physics-AI-ML/Research-Substrate/' "$case_dir/prompt.txt"; then
    fail 'production prompt still invents the personal research destination'
    return 1
  fi
  grep -qF 'If no configured research destination exists' "$case_dir/prompt.txt" \
    || { fail 'production prompt does not retain ordinary capture without a research destination'; return 1; }
  local today
  today="$(date '+%Y-%m-%d')"
  [ -f "$case_dir/vault/Projects/Marine-Systems/$today-reef-survey.md" ] \
    || { fail 'ordinary research session was not captured in its configured project'; return 1; }
  grep -qF "[[Projects/Marine-Systems/$today-reef-survey|Reef Survey]]" "$case_dir/vault/Journal/$today.md" \
    || { fail 'ordinary capture was not linked from the configured daily folder'; return 1; }
}

test_setup_template_persists_independent_choices() {
  local setup="$ROOT_DIR/skills/setup/SKILL.md"
  local failures=0

  grep -qF 'auto_save: AUTO_SAVE' "$setup" \
    || { printf 'FAIL: setup template does not persist the selected auto_save value\n' >&2; failures=1; }
  grep -qF 'keeper_autostart: KEEPER_AUTOSTART' "$setup" \
    || { printf 'FAIL: setup template does not persist the selected keeper_autostart value\n' >&2; failures=1; }
  grep -qF "\`AUTO_SAVE\`" "$setup" \
    || { printf 'FAIL: setup instructions do not map the autosave answer into the template\n' >&2; failures=1; }
  grep -qF "\`KEEPER_AUTOSTART\`" "$setup" \
    || { printf 'FAIL: setup instructions do not map the scheduler answer into the template\n' >&2; failures=1; }
  return "$failures"
}

render_setup_config() {
  python3 - "$ROOT_DIR/skills/setup/SKILL.md" "$1" "$2" "$3" <<'PY'
import pathlib
import re
import sys

source, vault, auto_save, keeper_autostart = sys.argv[1:]
blocks = re.findall(r"^```[^\n]*\n(.*?)^```", pathlib.Path(source).read_text(), re.M | re.S)
templates = [block for block in blocks if block.startswith("---\nvault_path:")]
if len(templates) != 1:
    raise SystemExit("expected one production setup configuration template")
template = templates[0]
for field, placeholder in (("auto_save", "AUTO_SAVE"), ("keeper_autostart", "KEEPER_AUTOSTART")):
    if not re.search(rf"^{field}: {placeholder}$", template, re.M):
        raise SystemExit(f"setup does not persist the selected {field}")
values = {
    "VAULT_ABSOLUTE_PATH": vault,
    "VAULT_FOLDER_NAME": "Marine Cabin",
    "DOMAIN_LIST": "  - Marine",
    "TAXONOMY_HEADER": "| Domain | Vault path | Precedence | Notes |",
    "TAXONOMY_SEPARATOR": "|--------|------------|------------|-------|",
    "TAXONOMY_ROWS": "| Marine | Projects/Marine-Systems/ | 10 | Field research |",
    "DAILY_AND_INBOX_ROWS": "| Daily | Journal/ | 50 | |\n| Inbox | Unfiled/ | 99 | |",
    "ROUTING_RULE_LINES": '- Keywords "reef, vessel" -> Projects/Marine-Systems/',
    "DAILY_PATH": "Journal/",
    "INBOX_PATH": "Unfiled/",
    "AUTO_SAVE": auto_save,
    "KEEPER_AUTOSTART": keeper_autostart,
}
for placeholder, value in values.items():
    template = template.replace(placeholder, value)
print(template, end="")
PY
}

test_rendered_setup_choices() {
  local case_dir auto_save keeper_autostart config
  case_dir="$(mktemp -d "${TMPDIR:-/tmp}/obsidian-setup-choices-XXXXXX")" || return 1
  trap 'rm -rf "$case_dir"; trap - RETURN' RETURN
  mkdir -p "$case_dir/bin" "$case_dir/home" "$case_dir/tmp" "$case_dir/Marine Cabin"
  printf -- '---\ntags: [marine]\ntype: note\n---\nFixture note\n' > "$case_dir/Marine Cabin/example.md"
  cat > "$case_dir/bin/nohup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 10 ] && [ "$1" = python3 ] &&
  [ "$2" = "${EXPECTED_SUMMARIZER:?}" ] && [ -f "$3" ] &&
  [ "$4" = "${OBSIDIAN_LOCAL_MD:?}" ] && [ "$5" = "${EXPECTED_VAULT:?}" ] || exit 99
printf 'save\n' >> "${CALLS:?}"
EOF
  cat > "$case_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = -s ] || exit 99
printf 'Darwin\n'
EOF
  cat > "$case_dir/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = list ] || exit 99
exit 0
EOF
  cat > "$case_dir/bin/install-fixture" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$1" = "${EXPECTED_TICK:?}" ] && [ "$2" = 900 ] || exit 99
printf 'install\n' >> "${CALLS:?}"
EOF
  cat > "$case_dir/bin/crontab" <<'EOF'
#!/usr/bin/env bash
printf 'stub: cron must not be used in the launchd fixture\n' >&2
exit 99
EOF
  chmod +x "$case_dir/bin/"*
  printf '%300s\n' transcript > "$case_dir/transcript.jsonl"
  for auto_save in false true; do
    for keeper_autostart in false true; do
      config="$case_dir/$auto_save-$keeper_autostart.md"
      render_setup_config "$case_dir/Marine Cabin" "$auto_save" "$keeper_autostart" > "$config" \
        || { fail 'could not render the actual setup template'; return 1; }
      if ! grep -qxF "auto_save: $auto_save" "$config" \
        || ! grep -qxF "keeper_autostart: $keeper_autostart" "$config"; then
        fail 'rendered setup choices differ from the selected values'; return 1
      fi
      : > "$case_dir/calls"
      printf '{"transcript_path":"%s"}' "$case_dir/transcript.jsonl" |
        env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/home/.config" \
          XDG_STATE_HOME="$case_dir/home/.local/state" \
          XDG_CACHE_HOME="$case_dir/home/.cache" TMPDIR="$case_dir/tmp" \
          PATH="$case_dir/bin:$PATH" KEEPER_OS=Darwin OBSIDIAN_SUMMARIZING= \
          OBSIDIAN_LOCAL_MD="$config" CALLS="$case_dir/calls" \
          EXPECTED_SUMMARIZER="$ROOT_DIR/scripts/lib/session-capture.py" \
          EXPECTED_VAULT="$case_dir/Marine Cabin" EXPECTED_TICK="$ROOT_DIR/scripts/vaultkeeper-tick.sh" \
          VAULTKEEPER_INSTALL="$case_dir/bin/install-fixture" \
          bash -c "trap wait EXIT; source \"\$0\"" "$ROOT_DIR/scripts/session-save.sh" \
        || { fail 'rendered configuration failed at the production Stop hook'; return 1; }
      if [ "$auto_save" = true ]; then
        grep -qxF save "$case_dir/calls" \
          || { fail 'selected autosave did not launch'; return 1; }
      elif grep -qxF save "$case_dir/calls"; then
        fail 'autosave ran after explicit opt-out'; return 1
      fi
      if [ "$auto_save" = true ] && [ "$keeper_autostart" = true ]; then
        grep -qxF install "$case_dir/calls" \
          || { fail 'selected watcher did not reach the installer'; return 1; }
      elif grep -qxF install "$case_dir/calls"; then
        fail 'the Stop hook installed a watcher without both required selections'; return 1
      fi
    done
  done
}

extract_bash_block() {
  python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys

source, marker = sys.argv[1:]
blocks = re.findall(r"^```bash\n(.*?)^```", pathlib.Path(source).read_text(), re.M | re.S)
matches = [block for block in blocks if marker in block]
if len(matches) != 1:
    raise SystemExit(f"expected one executable {marker} block in {source}")
print(matches[0], end="")
PY
}

test_reorganization_resolution() {
  local case_dir source actual_vault
  case_dir="$(mktemp -d "${TMPDIR:-/tmp}/obsidian-reorg-portable-XXXXXX")" || return 1
  trap 'rm -rf "$case_dir"; trap - RETURN' RETURN
  mkdir -p "$case_dir/home" "$case_dir/Marine # Cabin"
  cat > "$case_dir/config.md" <<EOF
---
vault_path: "$case_dir/Marine # Cabin"
---

## Project Taxonomy

| Domain | Vault path | Notes |
|--------|------------|-------|
| Marine | Projects/Marine-Systems/ | Field research |
EOF
  for source in skills/reorganize/SKILL.md agents/vault-organizer.md; do
    extract_bash_block "$ROOT_DIR/$source" 'obsidian_config_value vault_path' > "$case_dir/resolve.sh" \
      || { fail 'reorganization does not use an executable shared config reader'; return 1; }
    printf '\nprintf "%%s\\n" "%s" "%s"\n' "\$VAULT" "\$ALLOWED_FOLDERS" >> "$case_dir/resolve.sh"
    env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/home/.config" \
      CLAUDE_PLUGIN_ROOT="$ROOT_DIR" OBSIDIAN_LOCAL_MD="$case_dir/config.md" \
      bash "$case_dir/resolve.sh" > "$case_dir/resolved" \
      || { fail 'reorganization rejected the configured quoted vault path'; return 1; }
    IFS= read -r actual_vault < "$case_dir/resolved"
    if [ ! "$actual_vault" -ef "$case_dir/Marine # Cabin" ] \
      || ! grep -qxF 'Projects/Marine-Systems' "$case_dir/resolved"; then
      fail 'reorganization did not use the configured vault and taxonomy'; return 1
    fi
    if env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/home/.config" \
      CLAUDE_PLUGIN_ROOT="$ROOT_DIR" OBSIDIAN_LOCAL_MD="$case_dir/missing.md" \
      bash "$case_dir/resolve.sh" > "$case_dir/refused" 2>&1; then
      fail 'reorganization accepted a missing configuration'; return 1
    fi
    printf -- '---\nvault_path: "%s"\n---\n' "$case_dir/Marine # Cabin" > "$case_dir/no-taxonomy.md"
    if env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/home/.config" \
      CLAUDE_PLUGIN_ROOT="$ROOT_DIR" OBSIDIAN_LOCAL_MD="$case_dir/no-taxonomy.md" \
      bash "$case_dir/resolve.sh" > "$case_dir/refused" 2>&1; then
      fail 'reorganization accepted a missing taxonomy'; return 1
    fi
  done
}

test_manual_scheduler_without_autosave() {
  local source="$1" case_dir config
  case_dir="$(mktemp -d "${TMPDIR:-/tmp}/obsidian-setup-manual-XXXXXX")" || return 1
  trap 'rm -rf "$case_dir"; trap - RETURN' RETURN
  mkdir -p "$case_dir/bin" "$case_dir/home/.config/claude-obsidian" "$case_dir/Marine Cabin"
  config="$case_dir/home/.config/claude-obsidian/obsidian.local.md"
  render_setup_config "$case_dir/Marine Cabin" false true > "$config" \
    || { fail 'could not render scheduler-only setup'; return 1; }
  cat > "$case_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = -s ] || exit 99
printf 'Darwin\n'
EOF
  cat > "$case_dir/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$2" = "$HOME/Library/LaunchAgents/com.nhangen.obsidian-vaultkeeper.plist" ] || exit 99
case "$1" in
  unload|load) printf '%s\n' "$1" >> "${CALLS:?}" ;;
  *) exit 99 ;;
esac
EOF
  chmod +x "$case_dir/bin/"*
  extract_bash_block "$ROOT_DIR/$source" 'install-watcher.sh' > "$case_dir/install.sh" \
    || { fail 'scheduler-only setup has no executable manual installation'; return 1; }
  env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/home/.config" \
    PATH="$case_dir/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT_DIR" \
    OBSIDIAN_LOCAL_MD="$config" CALLS="$case_dir/calls" \
    bash "$case_dir/install.sh" > "$case_dir/result" 2>&1 \
    || { cat "$case_dir/result" >&2; fail 'documented scheduler-only installation failed on a fresh fixture host'; return 1; }
  grep -qxF load "$case_dir/calls" \
    || { fail 'scheduler-only setup did not load its fixture job'; return 1; }
  grep -qxF 'auto_save: false' "$config" \
    || { fail 'manual scheduler installation changed the autosave choice'; return 1; }
  render_setup_config "$case_dir/Marine Cabin" false false > "$config" \
    || { fail 'could not render scheduler opt-out'; return 1; }
  : > "$case_dir/calls"
  if env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/home/.config" \
    PATH="$case_dir/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT_DIR" \
    OBSIDIAN_LOCAL_MD="$config" CALLS="$case_dir/calls" \
    bash "$case_dir/install.sh" > "$case_dir/result" 2>&1; then
    fail 'manual installation accepted a scheduler opt-out'; return 1
  fi
  [ ! -s "$case_dir/calls" ] \
    || { fail 'manual installation touched the fixture scheduler after opt-out'; return 1; }
  render_setup_config "$case_dir/unavailable-remote-vault" false true > "$config" \
    || { fail 'could not render an unavailable-vault fixture'; return 1; }
  if env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/home/.config" \
    PATH="$case_dir/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT_DIR" \
    OBSIDIAN_LOCAL_MD="$config" CALLS="$case_dir/calls" \
    bash "$case_dir/install.sh" > "$case_dir/result" 2>&1; then
    fail 'manual installation accepted an inaccessible remote vault'; return 1
  fi
  [ ! -s "$case_dir/calls" ] \
    || { fail 'a client without vault access touched its fixture scheduler'; return 1; }
}

test_manual_installers() {
  local source
  for source in skills/setup/SKILL.md README.md; do
    test_manual_scheduler_without_autosave "$source" || return 1
  done
}

test_instruction_literals() {
  local source
  for source in skills/setup/SKILL.md skills/save-conversation/SKILL.md \
    skills/reorganize/SKILL.md agents/vault-organizer.md obsidian.local.md.example; do
    if grep -nE 'Projects/Physics-AI-ML/|/Users/nhangen/|/mnt/z/Users/nhang/|~/obsidian|keeper_host_priority: ml-1 mbp' "$ROOT_DIR/$source"; then
      fail "personal vault policy remains in $source"; return 1
    fi
  done
}

case "${1:-all}" in
  routing) test_summarizer_prompt_uses_configured_taxonomy ;;
  setup) test_setup_template_persists_independent_choices ;;
  choices) test_rendered_setup_choices ;;
  reorganize) test_reorganization_resolution ;;
  manual) test_manual_installers ;;
  literals) test_instruction_literals ;;
  all)
    failures=0
    test_summarizer_prompt_uses_configured_taxonomy || failures=1
    test_setup_template_persists_independent_choices || failures=1
    test_rendered_setup_choices || failures=1
    test_reorganization_resolution || failures=1
    test_manual_installers || failures=1
    test_instruction_literals || failures=1
    exit "$failures"
    ;;
  *) printf 'usage: %s [routing|setup|choices|reorganize|manual|literals|all]\n' "$0" >&2; exit 2 ;;
esac
