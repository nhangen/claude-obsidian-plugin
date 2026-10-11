#!/usr/bin/env bash
# keeper-monitor.sh — stateful transition monitoring and alerting for vaultkeeper.
# Tracks quarantine transitions and flagged note growth across ticks.
# Alerts through CEO/alerts/ and CEO/inbox.md only when CEO/alerts/ exists,
# and strictly on state transitions.
#
# Bash 3.2 and zsh clean. Requires note-hash.sh and keeper-state.sh.

_km_read_state_val() {
  local f="$1" k="$2"
  [ -f "$f" ] || return 1
  grep "^${k}=" "$f" 2>/dev/null | head -1 | sed "s/^${k}=//"
}

_km_iso8601() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ"
}

# keeper_monitor_tick <vault> <candidates_string> [host] [quarantine-only]
# quarantine-only is for a faulted scan: $cand is truncated, so the gap metrics are
# left exactly as the last healthy tick saved them. Quarantine reads the directory
# and is unaffected.
keeper_monitor_tick() {
  local vault="$1" cand="$2" host="${3:-$(hostname -s)}" scope="${4:-all}"
  local cache_dir state_file now now_iso rc=0
  cache_dir="$(keeper_cache_dir "$vault")" || {
    printf 'vaultkeeper: monitor skipped: no cache dir\n' >&2; return 0; }
  mkdir -p "$cache_dir" || {
    printf 'vaultkeeper: monitor skipped: cannot create %s\n' "$cache_dir" >&2; return 0; }
  state_file="$cache_dir/monitor.state"
  now="$(now_epoch)"
  now_iso="$(_km_iso8601)"

  # 1. Count current metrics
  local q_dir="$vault/.vaultkeeper-quarantine"
  local cur_q_count=0 q_files=""
  if [ -d "$q_dir" ]; then
    q_files="$(find "$q_dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | sort)"
    if [ -n "$q_files" ]; then
      cur_q_count="$(printf '%s\n' "$q_files" | grep -c . || true)"
    fi
  fi

  local cur_gap_count=0 cur_unfiled_count=0
  if [ -n "$cand" ]; then
    cur_gap_count="$(printf '%s\n' "$cand" | grep -c '^GAP'$'\t' || true)"
    cur_unfiled_count="$(printf '%s\n' "$cand" | grep -c '^UNFILED'$'\t' || true)"
  fi

  # 2. Read previous state
  local prev_q_status prev_q_count prev_q_since
  local prev_gap_status prev_gap_count prev_gap_since
  prev_q_status="$(_km_read_state_val "$state_file" "quarantine_status")" || prev_q_status="clear"
  prev_q_count="$(_km_read_state_val "$state_file" "quarantine_count")" || prev_q_count="0"
  prev_q_since="$(_km_read_state_val "$state_file" "quarantine_since")" || prev_q_since=""
  prev_gap_status="$(_km_read_state_val "$state_file" "gap_status")" || prev_gap_status="clear"
  local have_gap_state=1
  prev_gap_count="$(_km_read_state_val "$state_file" "gap_count")" || { prev_gap_count="$cur_gap_count"; have_gap_state=0; }
  prev_gap_since="$(_km_read_state_val "$state_file" "gap_since")" || prev_gap_since=""

  # 3. Determine new quarantine status & transition
  local new_q_status="clear" q_transition=0
  if [ "$cur_q_count" -gt 0 ]; then
    new_q_status="firing"
    if [ "$prev_q_status" != "firing" ]; then
      q_transition=1
      prev_q_since="$now_iso"
    fi
  else
    if [ "$prev_q_status" = "firing" ]; then
      q_transition=1
    fi
    prev_q_since=""
  fi

  # 4. Determine new gap status & transition (firing if growth >= 5)
  local new_gap_status="clear" gap_transition=0 gap_delta=0
  if [ "$scope" = "quarantine-only" ]; then
    cur_gap_count="$prev_gap_count"
    new_gap_status="$prev_gap_status"
  fi
  gap_delta=$(( cur_gap_count - prev_gap_count ))
  if [ "$scope" = "quarantine-only" ]; then
    :
  elif [ "$gap_delta" -ge 5 ]; then
    new_gap_status="firing"
    if [ "$prev_gap_status" != "firing" ]; then
      gap_transition=1
      prev_gap_since="$now_iso"
    fi
  elif [ "$cur_gap_count" -le "$prev_gap_count" ]; then
    new_gap_status="clear"
    if [ "$prev_gap_status" = "firing" ]; then
      gap_transition=1
    fi
    prev_gap_since=""
  else
    new_gap_status="$prev_gap_status"
  fi

  # 5. Alerting: gated strictly on $vault/CEO/alerts existence
  if [ -d "$vault/CEO/alerts" ]; then
    # Quarantine alert
    if [ "$q_transition" -eq 1 ] || [ "$new_q_status" = "firing" ]; then
      local q_alert_file="$vault/CEO/alerts/vaultkeeper-quarantine.md"
      local q_tmp
      q_tmp="$(mktemp "$vault/CEO/alerts/.qalert-XXXXXX" 2>/dev/null)" || q_tmp=""
      if [ -n "$q_tmp" ]; then
        {
          cat <<EOF
---
status: ${new_q_status}
since: ${prev_q_since:-$now_iso}
last_check: ${now_iso}
host: ${host}
---

# Vaultkeeper Quarantine

<!-- alert: [[CEO/alerts/vaultkeeper-quarantine]] -->

EOF
          if [ "$cur_q_count" -gt 0 ]; then
            printf 'Quarantined sync conflict copies awaiting resolution (%s):\n' "$cur_q_count"
            while IFS= read -r f; do
              [ -n "$f" ] || continue
              printf '  - `%s`\n' "$(basename "$f" | LC_ALL=C tr -d '`[:cntrl:]')"
            done <<<"$q_files"
            printf '\nRun `scripts/vaultkeeper-resolve-quarantine.sh` to review, diff, or discard.\n'
          else
            printf 'Quarantine is clear (no conflicting note copies).\n'
          fi
        } > "$q_tmp"
        # mktemp stages 0600; restore the alert's own mode so a swap cannot tighten it (#190).
        if keeper_preserve_mode "$q_tmp" "$q_alert_file"; then
          keeper_swap_or_clean "$q_tmp" "$q_alert_file" || rc=1
        else
          rm -f "$q_tmp"; rc=1
        fi
      fi

      # Escalate to inbox.md strictly on clear -> firing transition.
      # Under the keeper lock (#190): the check-then-append race with a concurrent
      # tick's escalation would duplicate the line, and a plain >> torn-write would
      # split a line the user then edits in Pending-style.
      if [ "$q_transition" -eq 1 ] && [ "$new_q_status" = "firing" ] && [ -f "$vault/CEO/inbox.md" ]; then
        local inbox_item="- [ ] Resolve ${cur_q_count} quarantined sync conflict(s) in .vaultkeeper-quarantine/ (run scripts/vaultkeeper-resolve-quarantine.sh)"
        if ! grep -qE '^- \[ \] Resolve [0-9]+ quarantined sync conflict' "$vault/CEO/inbox.md" 2>/dev/null; then
          local canonical q_inbox_lock
          canonical="$(cd "$vault" 2>/dev/null && pwd -P)" || canonical="$vault"
          q_inbox_lock="$(keeper_lock_acquire "$canonical")" || q_inbox_lock=""
          if [ -n "$q_inbox_lock" ]; then
            if ! grep -qE '^- \[ \] Resolve [0-9]+ quarantined sync conflict' "$vault/CEO/inbox.md" 2>/dev/null; then
              printf '\n%s\n' "$inbox_item" >> "$vault/CEO/inbox.md" || rc=1
            fi
            keeper_lock_release "$q_inbox_lock"
          else
            # Lock unavailable: fall through to the unlocked append, which is the
            # old behaviour and strictly better than silently dropping the task.
            printf '\n%s\n' "$inbox_item" >> "$vault/CEO/inbox.md" || rc=1
          fi
        fi
      fi
    fi

    # Gaps alert (written if firing or if transitioning)
    if [ "$scope" != "quarantine-only" ] && { [ "$gap_transition" -eq 1 ] || [ "$new_gap_status" = "firing" ]; }; then
      local gap_alert_file="$vault/CEO/alerts/vaultkeeper-gaps.md"
      local g_tmp
      g_tmp="$(mktemp "$vault/CEO/alerts/.galert-XXXXXX" 2>/dev/null)" || g_tmp=""
      if [ -n "$g_tmp" ]; then
        {
          cat <<EOF
---
status: ${new_gap_status}
since: ${prev_gap_since:-$now_iso}
last_check: ${now_iso}
host: ${host}
---

# Vaultkeeper Frontmatter Gaps

<!-- alert: [[CEO/alerts/vaultkeeper-gaps]] -->

Current gaps: ${cur_gap_count} (growth delta: +${gap_delta})
Unfiled notes: ${cur_unfiled_count}

EOF
          if [ "$new_gap_status" = "firing" ]; then
            printf 'Frontmatter gap count grew significantly. Run `scripts/vaultkeeper-backfill-frontmatter.sh` to backfill missing tags.\n'
          else
            printf 'Frontmatter gaps are stable or trending down.\n'
          fi
        } > "$g_tmp"
        # mktemp stages 0600; restore the alert's own mode so a swap cannot tighten it (#190).
        if keeper_preserve_mode "$g_tmp" "$gap_alert_file"; then
          keeper_swap_or_clean "$g_tmp" "$gap_alert_file" || rc=1
        else
          rm -f "$g_tmp"; rc=1
        fi
      fi

      # Escalate to inbox.md strictly on clear -> firing transition.
      # Under the keeper lock (#190): the check-then-append race with a concurrent
      # tick's escalation would duplicate the line, and a plain >> torn-write would
      # split a line the user then edits in Pending-style.
      if [ "$gap_transition" -eq 1 ] && [ "$new_gap_status" = "firing" ] && [ -f "$vault/CEO/inbox.md" ]; then
        local gap_inbox_item="- [ ] Frontmatter gaps grew (+${gap_delta}, total ${cur_gap_count}) (run scripts/vaultkeeper-backfill-frontmatter.sh)"
        if ! grep -qE '^- \[ \] Frontmatter gaps grew' "$vault/CEO/inbox.md" 2>/dev/null; then
          local canonical g_inbox_lock
          canonical="$(cd "$vault" 2>/dev/null && pwd -P)" || canonical="$vault"
          g_inbox_lock="$(keeper_lock_acquire "$canonical")" || g_inbox_lock=""
          if [ -n "$g_inbox_lock" ]; then
            if ! grep -qE '^- \[ \] Frontmatter gaps grew' "$vault/CEO/inbox.md" 2>/dev/null; then
              printf '\n%s\n' "$gap_inbox_item" >> "$vault/CEO/inbox.md" || rc=1
            fi
            keeper_lock_release "$g_inbox_lock"
          else
            # Lock unavailable: fall through to the unlocked append, which is the
            # old behaviour and strictly better than silently dropping the task.
            printf '\n%s\n' "$gap_inbox_item" >> "$vault/CEO/inbox.md" || rc=1
          fi
        fi
      fi
    fi
  fi

  # 6. Save state in cache
  local s_tmp
  s_tmp="$(mktemp "$cache_dir/.state-XXXXXX" 2>/dev/null)" || {
    printf 'vaultkeeper: monitor state not saved: cannot write %s\n' "$cache_dir" >&2; return 0; }
  {
    printf 'quarantine_status=%s\n' "$new_q_status"
    printf 'quarantine_count=%s\n' "$cur_q_count"
    printf 'quarantine_since=%s\n' "${prev_q_since}"
    if [ "$scope" != "quarantine-only" ] || [ "$have_gap_state" -eq 1 ]; then
      printf 'gap_status=%s\n' "$new_gap_status"
      printf 'gap_count=%s\n' "$cur_gap_count"
      printf 'gap_since=%s\n' "${prev_gap_since}"
    fi
    printf 'last_tick=%s\n' "$now"
  } > "$s_tmp"
  keeper_swap_or_clean "$s_tmp" "$state_file" || rc=1
  return "$rc"
}
