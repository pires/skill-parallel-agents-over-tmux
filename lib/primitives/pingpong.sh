#!/usr/bin/env bash
# Primitive: pingpong — two agents iterate on shared work via a buffer.
# Compatible with Bash 3.2+ (no associative arrays).

# Run a ping-pong loop.
# Arguments (all extracted from step JSON by the coordinator):
#   $1 - JSON object with fields:
#        agents: [agent1, agent2]
#        shared_buffer: buffer name
#        seed: initial buffer content (templates not yet resolved)
#        prompt: per-iteration instruction (with {{agent}} still to resolve)
#        max_iterations: number
#        nudge_mode: "auto" | "manual"
#        timeout: seconds per iteration
# Globals:
#   SWARM_INTERACTIVE - "true" to prompt user, "false" to fail on timeout
#   _lookup_pane - function from coordinator to resolve agent -> pane target
# Returns: 0 on success, 1 on failure
run_pingpong() {
  local config_json="$1"

  local agent1 agent2 shared_buffer seed prompt max_iterations nudge_mode timeout
  agent1=$(printf '%s' "$config_json" | jq -r '.agents[0]')
  agent2=$(printf '%s' "$config_json" | jq -r '.agents[1]')
  shared_buffer=$(printf '%s' "$config_json" | jq -r '.shared_buffer')
  seed=$(printf '%s' "$config_json" | jq -r '.seed // empty')
  prompt=$(printf '%s' "$config_json" | jq -r '.prompt')
  max_iterations=$(printf '%s' "$config_json" | jq -r '.max_iterations // 4')
  nudge_mode=$(printf '%s' "$config_json" | jq -r '.nudge_mode // "auto"')
  timeout=$(printf '%s' "$config_json" | jq -r '.timeout // 300')

  local target1 target2
  target1=$(_lookup_pane "$agent1") || {
    log_error "pingpong: unknown agent '$agent1'"
    return 1
  }
  target2=$(_lookup_pane "$agent2") || {
    log_error "pingpong: unknown agent '$agent2'"
    return 1
  }

  # Non-interactive context forces auto mode
  # Force auto mode if non-interactive or stdin is not a terminal
  if [[ "${SWARM_INTERACTIVE:-true}" != "true" || ! -t 0 ]]; then
    nudge_mode="auto"
  fi

  log_step "pingpong STARTED (${agent1} <-> ${agent2}, buffer: ${shared_buffer}, ${max_iterations} iterations, mode: ${nudge_mode})"

  # Seed the shared buffer (resolve templates so {{buffer:...}} etc. expand)
  if [[ -n "$seed" ]]; then
    local resolved_seed
    resolved_seed=$(resolve_templates "$seed")
    tmux_set_buffer "$shared_buffer" "$resolved_seed"
    log_info "pingpong: seeded buffer '$shared_buffer'"
  fi

  # Warn if shared_buffer doesn't match the buffer prefix
  if [[ -n "${SWARM_BUFFER_PREFIX:-}" && "$shared_buffer" != "${SWARM_BUFFER_PREFIX}"* ]]; then
    log_warn "pingpong: shared_buffer '$shared_buffer' does not start with buffer prefix '${SWARM_BUFFER_PREFIX}' — may collide with other runs"
  fi

  # Alternate between agents
  local iter=1
  while [[ "$iter" -le "$max_iterations" ]]; do
    local idx=$(( (iter - 1) % 2 ))
    local current_agent current_target
    if [[ "$idx" -eq 0 ]]; then
      current_agent="$agent1"; current_target="$target1"
    else
      current_agent="$agent2"; current_target="$target2"
    fi

    log_step "pingpong iter ${iter}/${max_iterations} (${current_agent}) STARTED"

    # Resolve {{agent}} in prompt for this iteration
    SWARM_CURRENT_AGENT="$current_agent"
    local resolved_prompt
    resolved_prompt=$(resolve_templates "$prompt")

    # Manual mode: ask human before nudging
    if [[ "$nudge_mode" == "manual" && "$iter" -gt 1 ]]; then
      local prev_agent
      if [[ "$((( iter - 2) % 2))" -eq 0 ]]; then
        prev_agent="$agent1"
      else
        prev_agent="$agent2"
      fi
      echo ""
      echo "[swarm] ${prev_agent} finished iteration $((iter - 1)). Send to ${current_agent}? [y/n/edit/abort]"
      local choice
      read -r choice
      case "$choice" in
        n)
          log_info "pingpong: user skipped nudge to ${current_agent}, re-nudging ${prev_agent}"
          current_agent="$prev_agent"
          if [[ "$prev_agent" == "$agent1" ]]; then
            current_target="$target1"
          else
            current_target="$target2"
          fi
          SWARM_CURRENT_AGENT="$current_agent"
          resolved_prompt=$(resolve_templates "$prompt")
          ;;
        edit)
          local tmpfile
          tmpfile=$(mktemp /tmp/swarm-edit-XXXXXX.md)
          tmux_get_buffer "$shared_buffer" > "$tmpfile"
          "${EDITOR:-vi}" "$tmpfile"
          tmux_set_buffer "$shared_buffer" "$(cat "$tmpfile")"
          rm -f "$tmpfile"
          log_info "pingpong: user edited buffer before iteration $iter"
          ;;
        abort)
          log_warn "pingpong: aborted by user at iteration $iter"
          return 0
          ;;
        *)
          # y or anything else: continue
          ;;
      esac
    fi

    # Clear completion signals before nudging (must happen before send-keys
    # so a fast agent's valid signal isn't deleted after it fires)
    local prefix="${SWARM_BUFFER_PREFIX:-}"
    local status_buffer="${prefix}status-${current_agent}"
    local sentinel_file="/tmp/swarm/${prefix}${current_agent}.done"
    tmux_delete_buffer "$status_buffer"
    rm -f "$sentinel_file"
    mkdir -p /tmp/swarm

    # Check pane activity before nudging
    if tmux_pane_is_active "$current_target"; then
      log_info "Pane $current_target is active, waiting for idle..."
      tmux_wait_for_idle "$current_target" || true
    fi

    # Nudge the agent
    tmux_send_keys "$current_target" "$resolved_prompt"

    local elapsed=0
    local poll_interval=2
    local completed=false

    while [[ "$elapsed" -lt "$timeout" ]]; do
      local status
      status=$(tmux_get_buffer "$status_buffer")
      if [[ "$status" == "done" ]]; then
        tmux_delete_buffer "$status_buffer"
        completed=true
        break
      fi

      if [[ -f "$sentinel_file" ]]; then
        rm -f "$sentinel_file"
        completed=true
        break
      fi

      sleep "$poll_interval"
      elapsed=$(( elapsed + poll_interval ))
    done

    if [[ "$completed" != "true" ]]; then
      log_error "pingpong iter ${iter}/${max_iterations} (${current_agent}) TIMED OUT after ${timeout}s"

      if [[ "${SWARM_INTERACTIVE:-true}" == "true" && -t 0 ]]; then
        echo ""
        echo "[swarm] ${current_agent} timed out on iteration ${iter}. [r]etry / [s]kip / [a]bort?"
        local timeout_choice
        read -r timeout_choice
        case "$timeout_choice" in
          r)
            log_info "pingpong: retrying iteration $iter"
            continue
            ;;
          s)
            log_warn "pingpong: skipping iteration $iter"
            ;;
          a|*)
            log_warn "pingpong: aborted after timeout at iteration $iter"
            return 1
            ;;
        esac
      else
        # Non-interactive: fail immediately
        return 1
      fi
    else
      log_step "pingpong iter ${iter}/${max_iterations} (${current_agent}) COMPLETED (${elapsed}s)"
    fi

    iter=$(( iter + 1 ))
  done

  log_step "pingpong COMPLETED (${max_iterations} iterations)"
  return 0
}
