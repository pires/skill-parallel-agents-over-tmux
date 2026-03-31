#!/usr/bin/env bash
# Primitive: parallel — run N tasks concurrently, wait for all.

# Parallel task registry — populated by parallel_add_task, consumed by run_parallel.
declare -a _parallel_agents=()
declare -a _parallel_targets=()
declare -a _parallel_prompt_files=()
declare -a _parallel_timeouts=()
declare -a _parallel_pids=()

# Register a task for the next run_parallel call.
# Prompts are written to temp files to preserve multiline content.
# Arguments:
#   $1 - agent name
#   $2 - pane target
#   $3 - prompt text (may be multiline)
#   $4 - timeout in seconds for this task
parallel_add_task() {
  local agent="$1"
  local target="$2"
  local prompt="$3"
  local timeout="${4:-300}"

  _parallel_agents+=("$agent")
  _parallel_targets+=("$target")
  _parallel_timeouts+=("$timeout")

  local prompt_file
  prompt_file=$(mktemp /tmp/swarm-parallel-XXXXXX)
  printf '%s' "$prompt" > "$prompt_file"
  _parallel_prompt_files+=("$prompt_file")
}

# Run all registered tasks in parallel, each with its own timeout.
# Returns: 0 if all succeeded, 1 if any failed
run_parallel() {
  _parallel_pids=()
  local count=${#_parallel_agents[@]}

  # Snapshot the registry then reset immediately so a failure mid-run
  # doesn't leave stale state for the next parallel_add_task cycle.
  local -a agents=("${_parallel_agents[@]}")
  local -a targets=("${_parallel_targets[@]}")
  local -a prompt_files=("${_parallel_prompt_files[@]}")
  local -a timeouts=("${_parallel_timeouts[@]}")
  _parallel_agents=()
  _parallel_targets=()
  _parallel_prompt_files=()
  _parallel_timeouts=()
  log_step "parallel STARTED ($count agents)"

  # Launch each task in background
  local -a pids=()
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    local agent="${agents[$i]}"
    local target="${targets[$i]}"
    local timeout="${timeouts[$i]}"
    local prompt
    prompt=$(cat "${prompt_files[$i]}")

    (
      SWARM_INTERACTIVE=false
      run_task "$agent" "$target" "$prompt" "$timeout"
    ) &
    pids+=($!)
    i=$(( i + 1 ))
  done

  # Wait for all background tasks
  local failed=0
  for i in "${!pids[@]}"; do
    local pid="${pids[$i]}"
    local agent="${agents[$i]}"
    if ! wait "$pid"; then
      log_error "parallel: task '$agent' failed"
      failed=$(( failed + 1 ))
    fi
  done

  # Cleanup temp files
  for f in "${prompt_files[@]}"; do
    rm -f "$f"
  done

  if [[ "$failed" -gt 0 ]]; then
    log_error "parallel COMPLETED with $failed failures"
    return 1
  fi

  log_step "parallel COMPLETED ($count agents, all succeeded)"
  return 0
}
