# /swarm — coordinate parallel AI agents over tmux

A skill that lets AI agents (Claude, Codex, Gemini, or any terminal-based
LLM) collaborate through tmux. Agents brainstorm in parallel, review each
other's work in ping-pong loops, and converge on results — all in live
tmux panes you can watch and interrupt.

In Claude Code:

```text
/swarm design a rate limiter for our API
```

In Codex, the skill triggers from the description when you ask about
multi-agent collaboration.

The skill discovers your agent panes, generates a workflow manifest,
launches a coordinator in a separate tmux window, and orchestrates the
collaboration. You approve each handoff or let it run fully automatic.

## Why

- **Model mixing**: use Claude for design, Codex for implementation,
  both reviewing each other's work
- **Full transparency**: every agent works in a visible tmux pane
- **Human-in-the-loop**: jump into any pane and redirect an agent,
  or approve each handoff in manual mode
- **No vendor lock-in**: works with any agent that runs in a terminal
  and can execute shell commands

## Install

```bash
git clone https://github.com/YOUR_USER/skill-parallel-agents-over-tmux.git
cd skill-parallel-agents-over-tmux
brew install jq yq  # if not already installed
```

### Claude Code

Symlink the skill directory into your project:

```bash
# From the repo root (skill/ is a sibling of .claude/):
ln -s ../skill .claude/skills

# Or from another project, use an absolute path:
ln -s /path/to/skill-parallel-agents-over-tmux/skill .claude/skills
```

This makes `skill/swarm/SKILL.md` discoverable as
`.claude/skills/swarm/SKILL.md`. Then invoke with `/swarm`.

### Codex

Symlink into Codex's skill directory:

```bash
ln -s /path/to/skill-parallel-agents-over-tmux/skill/swarm ~/.codex/skills/swarm
```

The `SKILL.md` has the required YAML frontmatter (`name`, `description`)
so Codex discovers it automatically.

### Other Agents

Point the agent at the skill file:

```text
Follow the instructions in skill/swarm/SKILL.md from the swarm project.
```

## Quickstart

### 1. Set up two agents in tmux

Open Claude in one pane, Codex in another — however you normally work.

### 2. Find your pane IDs

```bash
tmux list-panes -a -F '#{pane_id} #{pane_current_command}'
```

```text
%11 claude
%12 codex
```

Use the `%`-prefixed IDs. These are stable — they don't shift when
you split or close panes.

### 3. Invoke the skill

In Claude Code:

```text
/swarm design a rate limiter for our API
```

In Codex, ask naturally: "coordinate with Claude to design a rate limiter."

The skill will:

1. Discover your agent panes
2. Generate a manifest
3. Show you the plan and ask for confirmation
4. Launch the coordinator in a new tmux window (`swarm`)
5. Nudge agents and manage handoffs

### 4. Watch and interact

- **Agents' panes**: see live output as each agent works
- **Swarm window** (`Ctrl-b n`): approve handoffs in manual mode
- **Jump in**: switch to any agent pane and type to redirect it
- **Read the result**: `tmux show-buffer -b <run-id>-work` (the skill tells you the exact buffer name)

## How It Works

```text
You invoke /swarm
        │
        ▼
Skill discovers panes ──→ Generates manifest ──→ Launches coordinator
                                                        │
                                    ┌───────────────────┤
                                    ▼                   ▼
                              Nudge Agent 1       Nudge Agent 2
                              via send-keys       via send-keys
                                    │                   │
                                    ▼                   ▼
                              Agent reads         Agent reads
                              shared buffer       shared buffer
                                    │                   │
                                    ▼                   ▼
                              Agent writes        Agent writes
                              revision back       revision back
                                    │                   │
                                    ▼                   ▼
                              Signals done        Signals done
                              (status buffer)     (status buffer)
                                    │                   │
                                    └───────┬───────────┘
                                            ▼
                                    Coordinator detects
                                    completion, nudges
                                    next agent (or asks
                                    you in manual mode)
```

**Data flow**: tmux named buffers (`set-buffer` / `show-buffer`).
**Nudging**: `tmux send-keys` types the prompt into the agent's pane.
**Completion**: agent writes `done` to a status buffer; coordinator polls.

## Workflow Primitives

| Primitive    | Description                                              |
|--------------|----------------------------------------------------------|
| **task**     | Nudge one agent, wait for completion                     |
| **parallel** | Nudge N agents simultaneously, wait for all              |
| **sequence** | Run steps in order, output from one feeds the next       |
| **pingpong** | Two agents iterate on shared work via a buffer           |

### Ping-Pong (the core pattern)

Two agents, one shared buffer. They take turns improving the work:

```text
Seed buffer → Claude improves → Codex improves → Claude improves → done
```

Each iteration: coordinator nudges the agent, agent reads the buffer,
writes a better version back, signals done. The coordinator passes the
buffer to the other agent.

### Parallel Brainstorm → Ping-Pong Review

The most powerful pattern: agents brainstorm independently in parallel,
then converge through iterative review.

The skill generates a scoped manifest automatically. Buffer names are
prefixed with a unique run ID (e.g., `swarm-1711843200-12345-`) to
avoid collisions between concurrent runs. See `skill/swarm/SKILL.md`
for the full manifest templates.

Example (abbreviated — the skill fills in buffer prefixes and pane IDs):

```yaml
version: "1"
name: "swarm-1711843200-12345"

panes:
  claude:
    target: "%11"
  codex:
    target: "%12"

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
            Brainstorm 3 architectures for WebSocket notifications.
            Write to file then buffer, then signal done.
        - id: brainstorm-codex
          type: task
          agent: codex
          prompt: |
            Brainstorm 3 architectures for WebSocket notifications.
            Write to file then buffer, then signal done.
    - id: review
      type: pingpong
      agents: [claude, codex]
      shared_buffer: swarm-1711843200-12345-work
      nudge_mode: auto
      max_iterations: 3
      seed: |
        Claude's ideas: {{buffer:swarm-1711843200-12345-result-claude}}
        Codex's ideas: {{buffer:swarm-1711843200-12345-result-codex}}
        Synthesize and produce a concrete design.
      prompt: |
        Read, improve, write back to buffer, signal done.
```

## Manifest Format

Manifests are YAML files that define which agents to coordinate and how.

```yaml
version: "1"
name: "swarm-1711843200-12345"   # used as buffer prefix for scoping

panes:
  claude:
    target: "%11"                # stable tmux pane ID
    bootstrap:                   # optional: commands before workflow starts
      - "ctx agent --budget 8000"
    bootstrap_delay: 15          # seconds to wait after bootstrap (default: 10)
  codex:
    target: "%12"

workflow:
  type: pingpong                 # or: task, parallel, sequence
  agents: [claude, codex]
  shared_buffer: swarm-1711843200-12345-work
  nudge_mode: manual             # or: auto
  max_iterations: 4
  timeout: 300                   # seconds per iteration
  seed: |
    Initial content for the shared buffer.
  prompt: |
    Per-iteration instruction sent to each agent.
```

**`seed`** is the initial content of the shared buffer — the "what."
**`prompt`** is the per-iteration instruction — the "how."

### Templates

| Pattern | Resolves to |
|---------|-------------|
| `{{buffer:<name>}}` | Contents of a tmux named buffer |
| `{{agent}}` | Current agent name |

## Nudge Modes

**Manual** (default for `/swarm`): the coordinator pauses after each
agent finishes and asks you:

```text
[swarm] Claude finished iteration 1. Send to Codex? [y/n/edit/abort]
```

- `y` — send to the next agent
- `n` — re-nudge the same agent
- `edit` — open the buffer in `$EDITOR` before passing it on
- `abort` — stop the workflow

**Auto**: agents iterate without waiting for you. Use for well-defined
tasks where you trust the agents to converge.

## Requirements

- **tmux** 3.2+ (for named buffer features)
- **bash** (the coordinator scripts)
- **jq** and **yq** (`brew install jq yq`)
- **Agents** that can execute shell commands (Claude Code, Codex, etc.)

## Project Layout

```text
bin/
  swarm                    # entry point
lib/
  coordinator.sh           # manifest parsing, workflow orchestration
  tmux.sh                  # buffer ops, send-keys, pane management
  primitives/
    task.sh                # single agent nudge + wait
    parallel.sh            # concurrent execution
    sequence.sh            # ordered steps
    pingpong.sh            # iteration loop with shared buffer
  utils/
    logging.sh             # timestamped event logging
    templates.sh           # {{...}} resolution
skill/
  swarm/
    SKILL.md               # skill definition (Codex-compatible, works with any agent)
docs/
  specs/
    swarm-design.md        # full design document
  workflows/
    examples/              # example manifests
tests/
  test_integration.sh      # integration tests (requires tmux)
```

## Troubleshooting

**Agent not responding**: switch to its pane — it may be waiting for
tool approval or showing an error. Agents need to be in a state where
they accept typed input.

**Wrong pane nudged**: verify pane IDs with
`tmux list-panes -a -F '#{pane_id} #{pane_current_command}'`. Always
use `%`-prefixed stable IDs, not positional indices like `:1.2`.

**Coordinator exited immediately**: check for missing dependencies
(`yq`, `jq`). Re-run with `bash bin/swarm session manifest.yaml`
directly to see the error.

**Pane indices shifted**: don't split panes in the agents' window
after writing the manifest. The coordinator runs in a separate window
to avoid this. Use stable `%`-prefixed pane IDs.

## License

MIT
