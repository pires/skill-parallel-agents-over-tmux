#!/usr/bin/env bash
# Primitive: task — nudge one agent, wait for completion.

# Run a single task: send prompt to agent, wait for completion signal.
# Arguments:
#   $1 - agent name (used for status buffer: status-<agent>)
#   $2 - pane target (e.g., "work:0.0")
#   $3 - prompt text (already resolved)
#   $4 - timeout in seconds (default: 300)
# Globals:
#   SWARM_INTERACTIVE - "true" to prompt user on timeout, "false" to fail immediately
# Returns: 0 on success, 1 on timeout/failure
run_task() {
  local agent="$1"
  local target="$2"
  local prompt="$3"
  local timeout="${4:-300}"

  local prefix="${SWARM_BUFFER_PREFIX:-}"
  local status_buffer="${prefix}status-${agent}"
  local sentinel_file="/tmp/swarm/${prefix}${agent}.done"

  # Clear any previous completion signal
  tmux_delete_buffer "$status_buffer"
  rm -f "$sentinel_file"
  mkdir -p /tmp/swarm

  log_step "task:${agent} STARTED (pane: $target, timeout: ${timeout}s)"

  # Check pane activity before nudging
  if tmux_pane_is_active "$target"; then
    log_info "Pane $target is active, waiting for idle..."
    tmux_wait_for_idle "$target"
  fi

  # Send the prompt
  tmux_send_keys "$target" "$prompt"

  # Poll for completion
  local elapsed=0
  local poll_interval=2

  while true; do
    # Check buffer-based signal
    local status
    status=$(tmux_get_buffer "$status_buffer")
    if [[ "$status" == "done" ]]; then
      tmux_delete_buffer "$status_buffer"
      log_step "task:${agent} COMPLETED (${elapsed}s, buffer signal)"
      return 0
    fi

    # Check file-based sentinel fallback
    if [[ -f "$sentinel_file" ]]; then
      rm -f "$sentinel_file"
      log_step "task:${agent} COMPLETED (${elapsed}s, file signal)"
      return 0
    fi

    # Check timeout
    if [[ "$elapsed" -ge "$timeout" ]]; then
      log_error "task:${agent} TIMED OUT after ${timeout}s"

      # Only prompt if running interactively and stdin is a terminal
      if [[ "${SWARM_INTERACTIVE:-true}" == "true" && -t 0 ]]; then
        echo ""
        echo "[swarm] ${agent} timed out after ${timeout}s. [r]etry / [s]kip / [a]bort?"
        local choice
        read -r choice
        case "$choice" in
          r)
            log_info "task:${agent} retrying (resending prompt, timeout reset)"
            tmux_delete_buffer "$status_buffer"
            rm -f "$sentinel_file"
            tmux_send_keys "$target" "$prompt"
            elapsed=0
            continue
            ;;
          s)
            log_warn "task:${agent} skipped by user"
            return 0
            ;;
          a|*)
            return 1
            ;;
        esac
      fi

      return 1
    fi

    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
  done
}
