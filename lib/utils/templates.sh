#!/usr/bin/env bash
# Template resolution for swarm manifests.
# MVP supports: {{buffer:<name>}} and {{agent}}
# Compatible with Bash 3.2+ (no associative arrays).

# Resolve all {{...}} templates in a string.
# Single-pass: each token is resolved and replaced exactly once,
# so buffer contents that happen to contain {{...}} are not re-expanded.
# Globals used: SWARM_CURRENT_AGENT
# Arguments:
#   $1 - the template string
# Returns:
#   resolved string on stdout
resolve_templates() {
  local text="$1"
  local result="$text"

  # Resolve {{agent}} -> current agent name
  if [[ -n "${SWARM_CURRENT_AGENT:-}" ]]; then
    result="${result//\{\{agent\}\}/$SWARM_CURRENT_AGENT}"
  fi

  # Resolve {{buffer:<name>}} -> tmux buffer contents (single pass)
  # Collect all unique buffer names first, then replace each once.
  local seen_names=""
  local tmp="$result"
  while [[ "$tmp" =~ \{\{buffer:([^}]+)\}\} ]]; do
    local buf_name="${BASH_REMATCH[1]}"
    # Deduplicate using a delimiter-separated string
    case ",$seen_names," in
      *",$buf_name,"*) ;;  # already seen
      *) seen_names="${seen_names:+$seen_names,}$buf_name" ;;
    esac
    # Remove the matched token from tmp so the regex advances
    tmp="${tmp#*\{\{buffer:${buf_name}\}\}}"
  done

  # Now resolve each unique buffer name once
  local IFS=','
  for buf_name in $seen_names; do
    local buf_content
    buf_content=$(tmux show-buffer -b "$buf_name" 2>/dev/null) || {
      log_warn "Template: buffer '$buf_name' not found"
      buf_content=""
    }
    local token="{{buffer:${buf_name}}}"
    result="${result//$token/$buf_content}"
  done

  printf '%s' "$result"
}
