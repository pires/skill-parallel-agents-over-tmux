#!/usr/bin/env bash
# Integration test: run swarm with mock agents in tmux.
# Mock agents are simple bash loops that read a prompt from send-keys,
# write to a buffer, and signal completion.
set -euo pipefail

SWARM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SESSION="swarm-test-$$"
PASS=0
FAIL=0

cleanup() {
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
  rm -rf /tmp/swarm
}
trap cleanup EXIT

# Get the first pane target for a session, respecting base-index config.
# Arguments:
#   $1 - session name
# Returns: pane target like "session:1.1" on stdout
first_pane() {
  tmux list-panes -t "$1" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | head -1
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $label"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $label (expected '$expected', got '$actual')"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $label (expected to contain '$needle')"
    FAIL=$(( FAIL + 1 ))
  fi
}

# ── Test: tmux buffer operations ──────────────────────────────────
test_buffers() {
  echo "Test: tmux buffer operations"

  source "$SWARM_ROOT/lib/utils/logging.sh"
  source "$SWARM_ROOT/lib/tmux.sh"

  # Set and get
  tmux_set_buffer "test-buf" "hello world"
  local content
  content=$(tmux_get_buffer "test-buf")
  assert_eq "set/get buffer" "hello world" "$content"

  # Delete
  tmux_delete_buffer "test-buf"
  content=$(tmux_get_buffer "test-buf")
  assert_eq "delete buffer" "" "$content"

  # Get nonexistent
  content=$(tmux_get_buffer "nonexistent-buffer-xyz")
  assert_eq "get nonexistent buffer" "" "$content"
}

# ── Test: template resolution ─────────────────────────────────────
test_templates() {
  echo "Test: template resolution"

  source "$SWARM_ROOT/lib/utils/logging.sh"
  source "$SWARM_ROOT/lib/tmux.sh"
  source "$SWARM_ROOT/lib/utils/templates.sh"

  # {{agent}} resolution
  SWARM_CURRENT_AGENT="claude"
  local result
  result=$(resolve_templates "status-{{agent}}")
  assert_eq "resolve {{agent}}" "status-claude" "$result"

  # {{buffer:X}} resolution
  tmux_set_buffer "test-ideas" "my ideas here"
  result=$(resolve_templates "Review: {{buffer:test-ideas}}")
  assert_contains "resolve {{buffer:X}}" "my ideas here" "$result"

  # No templates — pass through unchanged
  result=$(resolve_templates "plain text no templates")
  assert_eq "no templates" "plain text no templates" "$result"

  # Cleanup
  tmux_delete_buffer "test-ideas"
}

# ── Test: pane validation ─────────────────────────────────────────
test_pane_validation() {
  echo "Test: pane validation"

  source "$SWARM_ROOT/lib/utils/logging.sh"
  source "$SWARM_ROOT/lib/tmux.sh"

  # Create a test session
  tmux new-session -d -s "$TEST_SESSION" -x 80 -y 24
  local pane_target
  pane_target=$(first_pane "$TEST_SESSION")

  # Valid pane
  if tmux_pane_exists "$pane_target"; then
    echo "  PASS: existing pane detected"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: existing pane not detected (target: $pane_target)"
    FAIL=$(( FAIL + 1 ))
  fi

  # Invalid pane
  if ! tmux_pane_exists "nonexistent-session-xyz:99.99"; then
    echo "  PASS: nonexistent pane rejected"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: nonexistent pane not rejected"
    FAIL=$(( FAIL + 1 ))
  fi

  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}

# ── Test: task with mock agent ────────────────────────────────────
test_task_completion() {
  echo "Test: task completion signaling"

  source "$SWARM_ROOT/lib/utils/logging.sh"
  source "$SWARM_ROOT/lib/tmux.sh"
  source "$SWARM_ROOT/lib/utils/templates.sh"
  source "$SWARM_ROOT/lib/primitives/task.sh"

  # Create session with a mock agent (bash shell)
  tmux new-session -d -s "$TEST_SESSION" -x 80 -y 24
  local pane_target
  pane_target=$(first_pane "$TEST_SESSION")

  # Run a task that signals completion via buffer.
  # The mock "agent" is just the bash shell in the pane.
  SWARM_INTERACTIVE=false
  local result
  result=$(run_task "mock-agent" "$pane_target" \
    'tmux set-buffer -b status-mock-agent done' 10 2>&1) || true

  assert_contains "task completed via buffer" "COMPLETED" "$result"

  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}

# ── Test: task timeout ────────────────────────────────────────────
test_task_timeout() {
  echo "Test: task timeout"

  source "$SWARM_ROOT/lib/utils/logging.sh"
  source "$SWARM_ROOT/lib/tmux.sh"
  source "$SWARM_ROOT/lib/utils/templates.sh"
  source "$SWARM_ROOT/lib/primitives/task.sh"

  # Create session
  tmux new-session -d -s "$TEST_SESSION" -x 80 -y 24
  local pane_target
  pane_target=$(first_pane "$TEST_SESSION")

  # Run a task that never signals — should timeout
  SWARM_INTERACTIVE=false
  local result
  result=$(run_task "timeout-agent" "$pane_target" \
    'echo working' 4 2>&1) || true

  assert_contains "task timed out" "TIMED OUT" "$result"

  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}

# ── Run all tests ─────────────────────────────────────────────────
main() {
  echo "=== swarm integration tests ==="
  echo ""

  # Need tmux server running
  if ! tmux list-sessions &>/dev/null && ! tmux start-server 2>/dev/null; then
    echo "SKIP: tmux server not available"
    exit 0
  fi

  test_buffers
  echo ""
  test_templates
  echo ""
  test_pane_validation
  echo ""
  test_task_completion
  echo ""
  test_task_timeout
  echo ""

  echo "=== Results: $PASS passed, $FAIL failed ==="
  [[ "$FAIL" -eq 0 ]]
}

main
