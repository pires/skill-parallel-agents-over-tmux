#!/usr/bin/env bash
# Primitive: sequence — run steps in order.
# The coordinator calls this with an ordered list of step definitions.
# Each step can be a task, parallel, or pingpong — the coordinator
# dispatches to the right primitive. Sequence just enforces ordering.

# Run steps sequentially.
# This is called by the coordinator's dispatch loop. Sequence itself
# delegates back to the coordinator for each child step, since children
# can be any primitive type.
#
# Arguments:
#   $1 - JSON array of step definitions (from yq)
# Returns: 0 if all steps succeeded, 1 on first failure
run_sequence() {
  local steps_json="$1"
  local count
  count=$(printf '%s' "$steps_json" | jq 'length')

  log_step "sequence STARTED ($count steps)"

  local i=0
  while [[ "$i" -lt "$count" ]]; do
    local step
    step=$(printf '%s' "$steps_json" | jq -c ".[$i]")

    local step_id step_type
    step_id=$(printf '%s' "$step" | jq -r '.id // "step-'"$i"'"')
    step_type=$(printf '%s' "$step" | jq -r '.type')

    log_info "sequence: step $((i+1))/$count ($step_id, type: $step_type)"

    # Dispatch to the coordinator's step runner
    if ! dispatch_step "$step"; then
      log_error "sequence: step '$step_id' failed, aborting"
      return 1
    fi

    i=$(( i + 1 ))
  done

  log_step "sequence COMPLETED ($count steps)"
  return 0
}
