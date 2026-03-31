#!/usr/bin/env bash
# Structured logging for swarm coordinator.
# Writes to stderr always. Optionally appends to a file if SWARM_LOG_FILE is set.

swarm_log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts=$(date +"%Y-%m-%d %H:%M:%S")
  local line
  line=$(printf "[%s] [%s] %s" "$ts" "$level" "$msg")

  # Always write to stderr
  printf '%s\n' "$line" >&2

  # Optionally append to log file
  if [[ -n "${SWARM_LOG_FILE:-}" && "${SWARM_LOG_FILE:-}" != "/dev/stderr" ]]; then
    printf '%s\n' "$line" >> "$SWARM_LOG_FILE" 2>/dev/null || true
  fi
}

log_info()  { swarm_log "INFO"  "$@"; }
log_warn()  { swarm_log "WARN"  "$@"; }
log_error() { swarm_log "ERROR" "$@"; }
log_step()  { swarm_log "STEP"  "$@"; }
