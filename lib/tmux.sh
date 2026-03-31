#!/usr/bin/env bash
# tmux operations: buffer management, send-keys, pane validation, activity detection.

# Check that a tmux pane exists.
# Arguments:
#   $1 - pane target (e.g., "work:0.0")
# Returns: 0 if exists, 1 otherwise
tmux_pane_exists() {
  local target="$1"
  local pane_id
  pane_id=$(tmux display-message -t "$target" -p '#{pane_id}' 2>/dev/null) || return 1
  [[ -n "$pane_id" ]]
}

# Validate that all declared panes exist.
# Arguments:
#   $@ - list of pane targets
# Returns: 0 if all exist, 1 on first missing pane (logs error)
tmux_validate_panes() {
  local target
  for target in "$@"; do
    if ! tmux_pane_exists "$target"; then
      log_error "Pane not found: $target"
      return 1
    fi
  done
}

# Send keys to a pane (the nudge).
# Arguments:
#   $1 - pane target
#   $2 - text to send
tmux_send_keys() {
  local target="$1"
  local text="$2"
  tmux send-keys -t "$target" "$text" Enter
}

# Set a named buffer.
# Arguments:
#   $1 - buffer name
#   $2 - content
tmux_set_buffer() {
  local name="$1"
  local content="$2"
  tmux set-buffer -b "$name" "$content"
}

# Get contents of a named buffer.
# Arguments:
#   $1 - buffer name
# Returns: buffer contents on stdout, or empty string if missing
tmux_get_buffer() {
  local name="$1"
  tmux show-buffer -b "$name" 2>/dev/null || true
}

# Delete a named buffer (for clearing status signals).
# Arguments:
#   $1 - buffer name
tmux_delete_buffer() {
  local name="$1"
  tmux delete-buffer -b "$name" 2>/dev/null || true
}

# Check if a pane has had recent keyboard input.
# Uses tmux's pane_input_off and last activity tracking.
# Arguments:
#   $1 - pane target
#   $2 - threshold in seconds (default: 5)
# Returns: 0 if pane is active (human is typing), 1 if idle
tmux_pane_is_active() {
  local target="$1"
  local threshold="${2:-5}"
  local last_activity
  local now

  # pane_last_activity is a unix timestamp of last pane activity
  last_activity=$(tmux display-message -t "$target" -p '#{pane_last_activity}' 2>/dev/null) || return 1
  now=$(date +%s)

  local elapsed=$(( now - last_activity ))
  [[ "$elapsed" -lt "$threshold" ]]
}

# Wait until a pane is idle (no recent activity).
# Always returns 0 — this is advisory, never fatal.
# Arguments:
#   $1 - pane target
#   $2 - threshold in seconds (default: 5)
#   $3 - max wait in seconds (default: 60)
tmux_wait_for_idle() {
  local target="$1"
  local threshold="${2:-5}"
  local max_wait="${3:-60}"
  local waited=0

  while tmux_pane_is_active "$target" "$threshold"; do
    if [[ "$waited" -ge "$max_wait" ]]; then
      log_warn "Pane $target still active after ${max_wait}s, proceeding anyway"
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  return 0
}

# Paste a buffer into a pane (for large context injection).
# Arguments:
#   $1 - buffer name
#   $2 - pane target
tmux_paste_buffer() {
  local name="$1"
  local target="$2"
  tmux paste-buffer -b "$name" -t "$target"
}
