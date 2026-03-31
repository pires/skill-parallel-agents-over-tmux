#!/usr/bin/env bash
# Coordinator: parse YAML manifest, bootstrap agents, dispatch workflow.
# Compatible with Bash 3.2+ (no associative arrays).

# Global state — parallel indexed arrays (Bash 3.2 compatible)
# Agent name at index i -> pane target at same index, etc.
_pane_names=()
_pane_targets=()
_boot_names=()       # agents that have bootstrap commands
_boot_cmds=()        # newline-separated commands per agent
_boot_delays=()      # delay seconds per agent

# SWARM_INTERACTIVE controls whether timeout/manual prompts are shown.
# Background subshells must set this to "false" before calling primitives.
SWARM_INTERACTIVE="${SWARM_INTERACTIVE:-true}"

# SWARM_BUFFER_PREFIX scopes buffer names to avoid collisions between
# concurrent runs. Set from the manifest name (e.g., "swarm-1711843200-").
# When empty, buffers use unscoped names (backward compatible).
SWARM_BUFFER_PREFIX="${SWARM_BUFFER_PREFIX:-}"

# Look up a pane target by agent name.
# Arguments:
#   $1 - agent name
# Returns: pane target on stdout, or empty string if not found
_lookup_pane() {
  local name="$1"
  local i=0
  while [[ "$i" -lt "${#_pane_names[@]}" ]]; do
    if [[ "${_pane_names[$i]}" == "$name" ]]; then
      printf '%s' "${_pane_targets[$i]}"
      return 0
    fi
    i=$(( i + 1 ))
  done
  return 1
}

# Parse the manifest and populate globals.
# Arguments:
#   $1 - path to manifest YAML file
# Returns: 0 on success, 1 on parse error
parse_manifest() {
  local manifest="$1"

  if [[ ! -f "$manifest" ]]; then
    log_error "Manifest not found: $manifest"
    return 1
  fi

  # Validate required fields
  local version
  version=$(yq '.version' "$manifest")
  if [[ "$version" != '"1"' && "$version" != '1' ]]; then
    log_error "Unsupported manifest version: $version"
    return 1
  fi

  local name
  name=$(yq -r '.name // "unnamed"' "$manifest")
  log_info "Loading manifest: $name"

  # If the manifest name looks like a swarm run ID (contains a timestamp
  # or unique suffix), use it as the buffer prefix. This scopes all
  # buffer names so concurrent runs don't collide.
  if [[ "$name" == swarm-* ]]; then
    SWARM_BUFFER_PREFIX="${name}-"
    log_info "Buffer prefix: $SWARM_BUFFER_PREFIX"
  fi

  # Parse panes
  local pane_names_list
  pane_names_list=$(yq -r '.panes | keys[]' "$manifest")
  for pane_name in $pane_names_list; do
    local target
    target=$(yq -r ".panes.${pane_name}.target" "$manifest")
    _pane_names+=("$pane_name")
    _pane_targets+=("$target")

    # Parse bootstrap commands
    local bootstrap_count
    bootstrap_count=$(yq ".panes.${pane_name}.bootstrap | length // 0" "$manifest")
    if [[ "$bootstrap_count" -gt 0 ]]; then
      local cmds=""
      local i=0
      while [[ "$i" -lt "$bootstrap_count" ]]; do
        local cmd
        cmd=$(yq -r ".panes.${pane_name}.bootstrap[$i]" "$manifest")
        if [[ -n "$cmds" ]]; then
          cmds="${cmds}"$'\n'"${cmd}"
        else
          cmds="$cmd"
        fi
        i=$(( i + 1 ))
      done

      local delay
      delay=$(yq -r ".panes.${pane_name}.bootstrap_delay // 10" "$manifest")

      _boot_names+=("$pane_name")
      _boot_cmds+=("$cmds")
      _boot_delays+=("$delay")
    fi
  done

  log_info "Parsed ${#_pane_names[@]} panes"
  return 0
}

# Validate that all declared panes exist in tmux.
# Returns: 0 if all exist, 1 on first missing
validate_panes() {
  tmux_validate_panes "${_pane_targets[@]}"
}

# Send bootstrap commands to each pane and start its delay timer
# immediately after its last command. All panes bootstrap in parallel.
# Returns: 0 on success
run_bootstrap() {
  local count=${#_boot_names[@]}
  if [[ "$count" -eq 0 ]]; then
    return 0
  fi

  local pids=()
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    local agent="${_boot_names[$i]}"
    local cmds="${_boot_cmds[$i]}"
    local delay="${_boot_delays[$i]}"
    local target
    target=$(_lookup_pane "$agent")

    # Each pane bootstraps in its own background subshell:
    # send commands, then sleep its declared delay.
    (
      log_info "Bootstrapping $agent (pane: $target)"
      while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        log_info "  -> $cmd"
        tmux_send_keys "$target" "$cmd"
        sleep 1
      done <<< "$cmds"
      log_info "Waiting ${delay}s for $agent bootstrap..."
      sleep "$delay"
    ) &
    pids+=($!)
    i=$(( i + 1 ))
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  log_info "Bootstrap complete"
}

# Dispatch a single step to the appropriate primitive.
# Arguments:
#   $1 - JSON step definition
# Returns: 0 on success, 1 on failure
dispatch_step() {
  local step_json="$1"
  local step_type
  step_type=$(printf '%s' "$step_json" | jq -r '.type')

  case "$step_type" in
    task)
      dispatch_task "$step_json"
      ;;
    parallel)
      dispatch_parallel "$step_json"
      ;;
    sequence)
      local steps
      steps=$(printf '%s' "$step_json" | jq -c '.steps')
      run_sequence "$steps"
      ;;
    pingpong)
      run_pingpong "$step_json"
      ;;
    *)
      log_error "Unknown step type: $step_type"
      return 1
      ;;
  esac
}

# Dispatch a task step.
dispatch_task() {
  local step_json="$1"
  local agent prompt timeout_val
  agent=$(printf '%s' "$step_json" | jq -r '.agent')
  prompt=$(printf '%s' "$step_json" | jq -r '.prompt')
  timeout_val=$(printf '%s' "$step_json" | jq -r '.timeout // 300')

  local target
  target=$(_lookup_pane "$agent") || {
    log_error "Unknown agent: $agent"
    return 1
  }

  # Resolve templates
  SWARM_CURRENT_AGENT="$agent"
  prompt=$(resolve_templates "$prompt")

  run_task "$agent" "$target" "$prompt" "$timeout_val"
}

# Dispatch a parallel step.
# Children can be any primitive type (task, sequence, pingpong, or nested parallel).
# Task children use the parallel_add_task + run_parallel fast path.
# Non-task children are dispatched recursively in background subshells.
dispatch_parallel() {
  local step_json="$1"
  local parent_timeout
  parent_timeout=$(printf '%s' "$step_json" | jq -r '.timeout // 300')

  local count
  count=$(printf '%s' "$step_json" | jq '.steps | length')

  # Separate children into task nodes (use fast path) and compound nodes (dispatch)
  local has_tasks=false
  local compound_pids=()
  local compound_ids=()

  local i=0
  while [[ "$i" -lt "$count" ]]; do
    local child
    child=$(printf '%s' "$step_json" | jq -c ".steps[$i]")

    local child_type
    child_type=$(printf '%s' "$child" | jq -r '.type // "task"')

    if [[ "$child_type" == "task" ]]; then
      # Task node: register for parallel_add_task fast path
      has_tasks=true
      local agent prompt child_timeout
      agent=$(printf '%s' "$child" | jq -r '.agent')
      prompt=$(printf '%s' "$child" | jq -r '.prompt')
      child_timeout=$(printf '%s' "$child" | jq -r ".timeout // $parent_timeout")

      local target
      target=$(_lookup_pane "$agent") || {
        log_error "Unknown agent in parallel step: $agent"
        return 1
      }

      SWARM_CURRENT_AGENT="$agent"
      prompt=$(resolve_templates "$prompt")
      parallel_add_task "$agent" "$target" "$prompt" "$child_timeout"
    else
      # Compound node: dispatch in background subshell (non-interactive)
      local child_id
      child_id=$(printf '%s' "$child" | jq -r '.id // "compound-'"$i"'"')
      compound_ids+=("$child_id")
      (
        SWARM_INTERACTIVE=false
        dispatch_step "$child"
      ) &
      compound_pids+=($!)
    fi

    i=$(( i + 1 ))
  done

  # Run any registered task nodes in parallel (non-interactive)
  local task_failed=0
  if [[ "$has_tasks" == "true" ]]; then
    run_parallel || task_failed=1
  fi

  # Wait for any compound nodes
  local compound_failed=0
  for i in "${!compound_pids[@]}"; do
    if ! wait "${compound_pids[$i]}"; then
      log_error "parallel: compound step '${compound_ids[$i]}' failed"
      compound_failed=$(( compound_failed + 1 ))
    fi
  done

  if [[ "$task_failed" -gt 0 || "$compound_failed" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# Run the full workflow from a manifest file.
# Arguments:
#   $1 - path to manifest YAML file
# Returns: 0 on success, 1 on failure
run_workflow() {
  local manifest="$1"

  # Parse
  parse_manifest "$manifest" || return 1

  # Validate panes
  validate_panes || return 1

  # Bootstrap
  run_bootstrap

  # Extract workflow root and dispatch
  local workflow_json
  workflow_json=$(yq -o=json '.workflow' "$manifest")

  log_info "Starting workflow..."
  if dispatch_step "$workflow_json"; then
    log_info "Workflow completed successfully"
    return 0
  else
    log_error "Workflow failed"
    return 1
  fi
}
