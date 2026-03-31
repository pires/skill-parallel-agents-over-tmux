---
name: swarm
description: Coordinate parallel AI agents over tmux. Use when the user wants multiple agents (Claude, Codex, etc.) to collaborate — brainstorming in parallel, reviewing each other's work in ping-pong loops, or running sequential pipelines. Triggers on "swarm", "coordinate agents", "ping-pong", "parallel brainstorm", or any request for multi-agent collaboration over tmux.
disable-model-invocation: true
---

# swarm — coordinate parallel agents over tmux

Launch a coordinated workflow between agents running in tmux panes.

## Usage

From Claude Code: `/swarm design a rate limiter`
From Codex: the skill triggers automatically from the description.
From any agent: read and follow this file.

Arguments after the skill name are the task description. The skill
will ask for workflow type and agent selection interactively.

## Execution

### Step 1: Discover agent panes

```bash
tmux list-panes -a -F '#{pane_id} #{pane_current_command}'
```

Present discovered agents:

```text
Found agents:
  1. claude (%11)
  2. codex  (%12)
  3. gemini (%15)

Which agents should collaborate? [1,2,3 / all / pick a subset]
```

Use `%`-prefixed stable pane IDs (not positional indices like `:1.2`).
The user can select any subset. If they pick 3+ and choose pingpong,
explain that pingpong requires exactly 2 and ask which pair.

### Step 2: Determine the workflow

If `$ARGUMENTS` contains the task, use it. Otherwise ask:

```text
What should the agents work on?
Workflow type: [pingpong / parallel]
```

**Pingpong** requires exactly 2 agents. If the user selected more than
2, tell them pingpong supports exactly 2 and ask which pair to use.

**Parallel** supports any number of agents.

Generate a unique run ID for buffer scoping:

```bash
SWARM_RUN_ID="swarm-$(date +%s%N)-$$"
```

This uses nanosecond timestamp + PID to guarantee uniqueness even for
near-simultaneous launches. All buffer names in the manifest use this
prefix to avoid collisions between concurrent runs.

### Step 3: Generate the manifest

Create a manifest at `/tmp/${SWARM_RUN_ID}.yaml`.

**Pingpong** (exactly 2 agents iterate on shared work):

```yaml
version: "1"
name: "<SWARM_RUN_ID>"

panes:
  <agent1>:
    target: "<pane_id_1>"
  <agent2>:
    target: "<pane_id_2>"

workflow:
  type: pingpong
  agents: [<agent1>, <agent2>]
  shared_buffer: <SWARM_RUN_ID>-work
  nudge_mode: manual
  max_iterations: 4
  timeout: 300
  seed: |
    <user's task description>
  prompt: |
    Read the current work by running:
      tmux show-buffer -b <SWARM_RUN_ID>-work
    Improve it. Write your revision to a file, then update the buffer:
      cat > /tmp/<SWARM_RUN_ID>-revision.md << 'EOF'
      <your revised content here>
      EOF
      tmux set-buffer -b <SWARM_RUN_ID>-work "$(cat /tmp/<SWARM_RUN_ID>-revision.md)"
    Signal completion:
      tmux set-buffer -b <SWARM_RUN_ID>-status-{{agent}} done
```

**Parallel** (all agents work simultaneously):

```yaml
version: "1"
name: "<SWARM_RUN_ID>"

panes:
  <agent1>:
    target: "<pane_id_1>"
  <agent2>:
    target: "<pane_id_2>"

workflow:
  type: parallel
  timeout: 300
  steps:
    - id: "<agent1>-task"
      type: task
      agent: <agent1>
      prompt: |
        <user's task description>
        Write your output to a file, then store it in a buffer:
          cat > /tmp/<SWARM_RUN_ID>-output-<agent1>.md << 'EOF'
          <your output here>
          EOF
          tmux set-buffer -b <SWARM_RUN_ID>-result-<agent1> "$(cat /tmp/<SWARM_RUN_ID>-output-<agent1>.md)"
        Signal done:
          tmux set-buffer -b <SWARM_RUN_ID>-status-<agent1> done
    - id: "<agent2>-task"
      type: task
      agent: <agent2>
      prompt: |
        <user's task description>
        Write your output to a file, then store it in a buffer:
          cat > /tmp/<SWARM_RUN_ID>-output-<agent2>.md << 'EOF'
          <your output here>
          EOF
          tmux set-buffer -b <SWARM_RUN_ID>-result-<agent2> "$(cat /tmp/<SWARM_RUN_ID>-output-<agent2>.md)"
        Signal done:
          tmux set-buffer -b <SWARM_RUN_ID>-status-<agent2> done
```

**Parallel brainstorm then pingpong review** (the most powerful pattern):

```yaml
version: "1"
name: "<SWARM_RUN_ID>"

panes:
  <agent1>:
    target: "<pane_id_1>"
  <agent2>:
    target: "<pane_id_2>"

workflow:
  type: sequence
  steps:
    - id: brainstorm
      type: parallel
      steps:
        - id: brainstorm-<agent1>
          type: task
          agent: <agent1>
          prompt: |
            <brainstorm prompt>
            Write output to file then buffer:
              cat > /tmp/<SWARM_RUN_ID>-output-<agent1>.md << 'EOF'
              <your output>
              EOF
              tmux set-buffer -b <SWARM_RUN_ID>-result-<agent1> "$(cat /tmp/<SWARM_RUN_ID>-output-<agent1>.md)"
            Signal done:
              tmux set-buffer -b <SWARM_RUN_ID>-status-<agent1> done
        - id: brainstorm-<agent2>
          type: task
          agent: <agent2>
          prompt: |
            <brainstorm prompt>
            Write output to file then buffer:
              cat > /tmp/<SWARM_RUN_ID>-output-<agent2>.md << 'EOF'
              <your output>
              EOF
              tmux set-buffer -b <SWARM_RUN_ID>-result-<agent2> "$(cat /tmp/<SWARM_RUN_ID>-output-<agent2>.md)"
            Signal done:
              tmux set-buffer -b <SWARM_RUN_ID>-status-<agent2> done
    - id: review
      type: pingpong
      agents: [<agent1>, <agent2>]
      shared_buffer: <SWARM_RUN_ID>-work
      nudge_mode: manual
      max_iterations: 3
      seed: |
        <agent1>'s ideas: {{buffer:<SWARM_RUN_ID>-result-<agent1>}}
        <agent2>'s ideas: {{buffer:<SWARM_RUN_ID>-result-<agent2>}}
        Synthesize and improve.
      prompt: |
        Read: tmux show-buffer -b <SWARM_RUN_ID>-work
        Improve. Write to file then buffer:
          cat > /tmp/<SWARM_RUN_ID>-revision.md << 'EOF'
          <your revision>
          EOF
          tmux set-buffer -b <SWARM_RUN_ID>-work "$(cat /tmp/<SWARM_RUN_ID>-revision.md)"
        Signal done:
          tmux set-buffer -b <SWARM_RUN_ID>-status-{{agent}} done
```

### Step 4: Show the plan and confirm

```text
Swarm plan:
  Workflow: pingpong (manual, 4 iterations max)
  Agents: claude (%11) <-> codex (%12)
  Buffer: <SWARM_RUN_ID>-work
  Task: "design a rate limiter"
  Manifest: /tmp/<SWARM_RUN_ID>.yaml

Launch? [y/n/edit]
```

### Step 5: Launch the coordinator

The coordinator MUST run in a separate tmux window (not a split in
the agents' window — splitting renumbers pane indices).

```bash
tmux new-window -n swarm "bash <swarm-root>/bin/swarm session /tmp/<SWARM_RUN_ID>.yaml; echo '--- swarm finished ---'; read"
```

Replace `<swarm-root>` with the absolute path to the
skill-parallel-agents-over-tmux directory.

### Step 6: Report

For **pingpong**:

```text
Swarm launched in tmux window 'swarm'.
  - Switch to it (Ctrl-b n) to approve handoffs or see logs.
  - Read the result when done: tmux show-buffer -b <SWARM_RUN_ID>-work
```

For **parallel**:

```text
Swarm launched in tmux window 'swarm'.
  - Both agents are working simultaneously.
  - Read results when done:
      tmux show-buffer -b <SWARM_RUN_ID>-result-<agent1>
      tmux show-buffer -b <SWARM_RUN_ID>-result-<agent2>
```

For **sequence** (parallel + pingpong):

```text
Swarm launched in tmux window 'swarm'.
  - Phase 1: agents brainstorm in parallel.
  - Phase 2: agents review via ping-pong.
  - Read the final result: tmux show-buffer -b <SWARM_RUN_ID>-work
```

## Agent Prompt Contract

Every prompt sent to an agent MUST include these three explicit steps:

1. **Write to a file first**: `cat > /tmp/<run-id>-revision.md << 'EOF' ... EOF`
2. **Update the buffer from that file**: `tmux set-buffer -b <name> "$(cat /tmp/<run-id>-revision.md)"`
3. **Signal completion**: `tmux set-buffer -b <run-id>-status-<agent> done`

Never assume the agent will infer the temp file step. Always spell out
all three commands.

## Dependencies

- tmux 3.2+, bash, jq, yq
- The swarm coordinator: `bin/swarm` and `lib/` from this project
