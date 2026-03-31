# Swarm: tmux-native coordination for live agent sessions

## Problem

You have Claude in one tmux pane and Codex in another. Both are
bootstrapped with project context, MCP servers connected, conversation
history loaded. You want them to iterate on shared work — brainstorm in
parallel, review each other's output, converge on a design — without
you manually copy-pasting between panes.

There's no tool for this. You either do it by hand or use a
vendor-locked solution (Claude Agent Teams) that only supports one model
and hides the agents from you.

## Solution

A tmux-native coordination tool that connects your live agent sessions
through shared buffers and `send-keys` nudges. Agents read and write
named tmux buffers. A lightweight coordinator orchestrates who works
when, passing output between them automatically or with your approval.

The agents are cooperative terminal agents that can execute shell
commands and signal completion. Claude Code and Codex both qualify.

## Non-Goals

- Replacing tmux or building a custom terminal multiplexer
- CI/CD infrastructure or headless automation
- Supporting agents that cannot run shell commands
- A general-purpose workflow engine (Airflow, Temporal)
- Ephemeral/stateless agent execution (deferred)

---

## Architecture

### Design Principle

The agents do the thinking. tmux does the plumbing. The coordinator
is a thin shell script that nudges agents, watches for completion,
and passes buffers between panes.

### Core Concepts

| Concept | Implementation |
|---------|---------------|
| Agent isolation | tmux panes — each agent in its own pane |
| Data flow | tmux named buffers (`set-buffer` / `show-buffer`) |
| Nudging | `tmux send-keys -t pane "prompt" Enter` |
| Large context injection | `tmux paste-buffer -b name -t pane` |
| Completion signaling | Agent writes to buffer or touches sentinel file |
| Human observation | Switch to any pane, watch live |
| Human intervention | Type directly into any pane at any time |

### Workflow Primitives

Four building blocks:

| Primitive | Description |
|-----------|-------------|
| **task** | Single agent invocation via `send-keys` |
| **parallel** | N agents work simultaneously on the same or different prompts |
| **sequence** | Run steps in order, output from one feeds the next |
| **pingpong** | 2 agents iterate back and forth on shared work via a buffer |

A typical workflow is: `sequence` containing a `parallel` brainstorm
followed by a `pingpong` review. Primitives nest freely.

---

## How It Works

### Buffers as shared memory

tmux named buffers are the IPC mechanism. Any pane in the tmux server
can read or write any buffer.

```bash
# Agent writes its output
tmux set-buffer -b design "the improved design..."

# Another agent reads it
tmux show-buffer -b design

# Coordinator seeds a buffer before nudging
tmux set-buffer -b design "initial proposal..."
```

Buffer types:

- **Shared**: both agents read/write (the ping-pong ball)
- **Private**: one agent writes, the other reads (brainstorm outputs)

### Nudging agents

The coordinator sends prompts to agents via `send-keys`:

```bash
tmux send-keys -t %11 \
  "Read the current design from buffer 'design' by running: tmux show-buffer -b design. Improve it, then write your revision back with: tmux set-buffer -b design \"\$(cat /tmp/your-output.md)\"" Enter
```

For large context that would overwhelm `send-keys`, use `paste-buffer`:

```bash
tmux paste-buffer -b context -t %12
```

### Completion signaling

The agent signals "I'm done" by writing to a known buffer or
touching a sentinel file. The coordinator watches for it.

**Buffer-based**: agent writes to a status buffer:

```bash
# Coordinator instructs agent to signal when done:
# "When finished, run: tmux set-buffer -b status-claude done"
#
# Coordinator polls:
while [ "$(tmux show-buffer -b status-claude 2>/dev/null)" != "done" ]; do
  sleep 2
done
```

**File-based**: agent touches a sentinel:

```bash
# Agent runs: touch /tmp/swarm/task-1.done
# Coordinator watches:
while [ ! -f /tmp/swarm/task-1.done ]; do
  sleep 2
done
```

Both approaches require the agent to cooperate — it must be able to
execute shell commands, which Claude Code and Codex both can.

### Bootstrap

Agents often need context before they're useful. The coordinator sends
each bootstrap command via `send-keys`, then waits `bootstrap_delay`
seconds (default: 10) after the final command before starting the
workflow. One delay per pane, applied once after all that pane's
bootstrap commands have been sent.

```yaml
panes:
  claude:
    target: "%11"              # stable pane ID
    bootstrap:
      - "ctx agent --budget 8000"
    bootstrap_delay: 15       # seconds after last command (default: 10)
  codex:
    target: "%12"              # stable pane ID
    bootstrap:
      - "Read README.md and understand the project layout"
    # uses default 10s delay
```

This avoids the complexity of detecting "agent ready" states — the
human knows their agents and can tune the delay.

### Ping-pong in detail

The core interaction pattern. Two agents, one shared buffer:

```text
1. Coordinator seeds buffer 'design' with the initial prompt/context
2. Nudge Claude: "read buffer 'design', improve it, write back"
3. Wait for Claude to signal completion
4. Nudge Codex: "read buffer 'design', improve it, write back"
5. Wait for Codex to signal completion
6. Repeat for max_iterations or until convergence
```

What the human sees:

```text
+-------------------------------+-------------------------------+
|  %11 (Claude)                 |  %12 (Codex)                 |
|  [reviewing design v2...]     |  (last output visible)        |
|  (live, can scroll/interact)  |  (can switch here anytime)    |
+-------------------------------+-------------------------------+
```

**Nudge modes**:

- `auto`: agents iterate without human intervention (default)
- `manual`: coordinator pauses between iterations, human approves each nudge

In either mode, the human can switch to any pane and talk to the
agent directly at any time.

---

## Manifest Format

```yaml
version: "1"
name: "design-review"

panes:
  claude:
    target: "%11"              # stable pane ID
    bootstrap:
      - "ctx agent --budget 8000"
  codex:
    target: "%12"              # stable pane ID

workflow:
  type: pingpong
  agents: [claude, codex]
  shared_buffer: design
  nudge_mode: auto
  max_iterations: 4
  seed: |
    We're designing a rate limiter for our API.
    Requirements: sliding window algorithm, per-user and per-IP limits,
    Redis-backed state, comprehensive error handling.
    Produce a concrete design document.
  prompt: |
    Read the current design: tmux show-buffer -b design
    Improve it, then write your revision back:
      tmux set-buffer -b design "$(cat /tmp/revision.md)"
    Signal completion: tmux set-buffer -b status-{{agent}} done
```

The `seed` field defines the initial content of the shared buffer.
The `prompt` field is the per-iteration instruction sent to each
agent — it tells them how to read, work, write back, and signal.
These are always separate: `seed` is the "what", `prompt` is the "how".

### Parallel brainstorm then ping-pong

```yaml
version: "1"
name: "brainstorm-then-review"

panes:
  claude:
    target: "%11"              # stable pane ID
    bootstrap:
      - "ctx agent --budget 8000"
  codex:
    target: "%12"              # stable pane ID

workflow:
  type: sequence
  steps:
    - id: brainstorm
      type: parallel
      steps:
        - id: brainstorm-claude
          type: task
          agent: claude
          prompt: |
            Brainstorm 5 approaches to real-time notifications.
            Write your output: tmux set-buffer -b ideas-claude "$(cat /tmp/ideas.md)"
            Signal done: tmux set-buffer -b status-claude done

        - id: brainstorm-codex
          type: task
          agent: codex
          prompt: |
            Brainstorm 5 approaches to real-time notifications.
            Write your output: tmux set-buffer -b ideas-codex "$(cat /tmp/ideas.md)"
            Signal done: tmux set-buffer -b status-codex done

    - id: review
      type: pingpong
      agents: [claude, codex]
      shared_buffer: design
      nudge_mode: auto
      max_iterations: 3
      seed: |
        Two agents brainstormed independently:

        === Claude ===
        {{buffer:ideas-claude}}

        === Codex ===
        {{buffer:ideas-codex}}

        Synthesize the best ideas and produce a concrete design.
      prompt: |
        Read the current design: tmux show-buffer -b design
        Improve it. Write back: tmux set-buffer -b design "$(cat /tmp/revision.md)"
        Signal done: tmux set-buffer -b status-{{agent}} done
```

### Template resolution

MVP supports two templates:

| Pattern | Resolves to |
|---------|-------------|
| `{{buffer:<name>}}` | Contents of tmux named buffer |
| `{{agent}}` | Current agent name (for status signaling) |

Deferred:

| Pattern | Resolves to |
|---------|-------------|
| `{{iteration}}` | Current ping-pong iteration number |
| `{{file:<path>}}` | Contents of a file |

---

## Human Interaction

### Manual takeover

At any point, switch to a pane and talk to the agent directly.
The coordinator checks for pane activity (recent keyboard input)
before sending a nudge. If it detects you're interacting, it holds
off until you're done. This prevents nudge text from corrupting
your input.

### Nudge modes

**Auto** (default): agents iterate without waiting for you. Best for
well-defined tasks where you trust the agents to converge.

**Manual**: after each iteration, the coordinator prints in the
status area and waits for your approval:

```text
[swarm] Claude finished iteration 2. Send to Codex? [y/n/edit/abort]
```

- `y`: continue
- `n`: skip this nudge, keep iterating with the same agent
- `edit`: open the buffer in `$EDITOR` before passing it on
- `abort`: stop the workflow

### Switching modes mid-flight (deferred)

Planned for post-MVP: a `swarm-control` buffer that lets you pause
or switch to manual mode mid-flight. For MVP, choose `auto` or
`manual` in the manifest. To interrupt an auto workflow, switch to
a pane and talk to the agent directly, or kill the coordinator.

---

## Completion Signaling

The hardest problem in session mode. The agent is a live interactive
process — it doesn't exit when done.

### Approach: explicit agent cooperation

The prompt instructs the agent to signal completion by writing to
a status buffer:

```text
When finished, run: tmux set-buffer -b status-claude done
```

The coordinator polls this buffer. On detection, it clears the buffer
and proceeds to the next step.

This works because Claude Code and Codex can both execute shell
commands via their Bash/terminal tools.

### Fallback: file sentinel

If buffer signaling is unreliable, agents can touch a file:

```text
When finished, run: touch /tmp/swarm/claude.done
```

The coordinator watches with a polling loop. File sentinels are
slightly more debuggable (visible with `ls`) but require filesystem
access.

### Timeout

Every step has a timeout (default: 5 minutes). If the agent hasn't
signaled completion by then, the coordinator reports it and asks
what to do.

---

## File Layout

```text
swarm/
  bin/
    swarm                    # Entry point
  lib/
    coordinator.sh           # Main loop: parse manifest, orchestrate
    tmux.sh                  # Buffer ops, send-keys, pane management
    primitives/
      task.sh                # Single agent nudge + wait
      parallel.sh            # Concurrent tasks + collect
      sequence.sh            # Ordered steps with output threading
      pingpong.sh            # Iteration loop with shared buffer
    utils/
      logging.sh             # Timestamped event logging
      templates.sh           # {{...}} resolution
  skill/
    swarm/
      SKILL.md               # Skill definition (Codex-compatible)
  docs/
    specs/
      swarm-design.md        # This file
    workflows/
      examples/
        live-test.yaml       # Manual pingpong example
  tests/
    test_integration.sh      # Integration tests (requires tmux)
    fixtures/
      simple-pingpong.yaml
      simple-parallel.yaml
      simple-sequence.yaml
```

---

## MVP Scope

### In scope

- Session mode only (`swarm session <manifest>`)
- Pane targeting (attach to existing tmux panes)
- Bootstrap commands
- Shared and private tmux named buffers
- `send-keys` nudging with `paste-buffer` for large context
- Completion signaling (buffer-based + file sentinel fallback)
- Four primitives: `task`, `parallel`, `sequence`, `pingpong`
- Auto and manual nudge modes
- `{{buffer:X}}` and `{{agent}}` template resolution
- Timeout per step
- Coordinator logging

### Deferred

- Ephemeral mode (`swarm run` with `respawn-pane` and file-based IPC)
- Generic adapter registry
- Gate as a separate primitive (manual nudge mode covers this)
- Convergence detection (fixed iteration count is fine for now)
- Context strategies (window, delta)
- Workflow composition
- Cost tracking
- Broad "any CLI agent" positioning

### Success Criteria

Can you go from "I have Claude and Codex open in tmux" to "they're
productively iterating on shared work" in under a minute?

---

## Risks

**Completion signaling reliability**: agents must cooperate by running
the signal command. If an agent ignores the instruction or errors
before signaling, the coordinator hangs until timeout. Mitigation:
clear prompt templates with explicit signal instructions; timeout
as safety net.

**Buffer size limits**: tmux buffers are in-memory. For outputs
exceeding ~1 MB, agents should write to files and pass the path
through the buffer. Mitigation: document the pattern; prompt
templates use tmp files as intermediaries.

**Nudge prompt engineering**: the prompt sent via `send-keys` must
reliably get the agent to read the buffer, do work, write back, and
signal. Different agents may need different prompt styles. Mitigation:
per-agent prompt templates in the manifest.

**Human intervention timing**: if the human is typing in a pane when
the coordinator tries to nudge, the nudge text gets mixed into
the human's input. Mitigation: the coordinator checks pane activity
before nudging and holds off if the pane has recent keyboard input.
This is core behavior, not optional polish.

## Open Questions

1. ~~**How to detect "agent ready" after bootstrap?**~~ Resolved:
   fixed delay per pane (`bootstrap_delay`, default 10s) applied once
   after all bootstrap commands for that pane are sent. Simple,
   predictable, user-tunable.

2. ~~**Should the coordinator run in its own pane or as a background
   process?**~~ Resolved: coordinator runs in a separate tmux window
   (not a split in the agents' window, which would renumber pane indices).
   This gives visibility without interfering with agent pane IDs.

3. **How to handle agent tool approval prompts?** If Claude pauses
   for permission, the coordinator thinks it's still working. May
   need agents in auto-approve mode.

4. **Buffer naming convention?** `swarm-<workflow>-<step>` to avoid
   collisions with user buffers?
