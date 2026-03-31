# Decisions

<!-- INDEX:START -->
| Date | Decision |
|------|--------|
| 2026-03-31 | Markdown lint via podman, enforced by pre-commit hook |
| 2026-03-31 | Docs live in docs/, not scattered at root |
| 2026-03-31 | Skill lives in skill/ with symlinks for agent discovery |
| 2026-03-30 | Session mode is the only MVP, ephemeral mode deferred |
| 2026-03-30 | tmux named buffers as IPC |
| 2026-03-30 | Shell-based coordinator, no compiled binary |
| 2026-03-30 | Two coordination modes: ephemeral and session |
<!-- INDEX:END -->

<!-- DECISION FORMATS

## Quick Format (Y-Statement)

For lightweight decisions, a single statement suffices:

> "In the context of [situation], facing [constraint], we decided for [choice]
> and against [alternatives], to achieve [benefit], accepting that [trade-off]."

## Full Format

For significant decisions:

## [YYYY-MM-DD] Decision Title

**Status**: Accepted | Superseded | Deprecated

**Context**: What situation prompted this decision? What constraints exist?

**Alternatives Considered**:
- Option A: [Pros] / [Cons]
- Option B: [Pros] / [Cons]

**Decision**: What was decided?

**Rationale**: Why this choice over the alternatives?

**Consequence**: What are the implications? (Include both positive and negative)

**Related**: See also [other decision] | Supersedes [old decision]

## When to Record a Decision

✓ Trade-offs between alternatives
✓ Non-obvious design choices
✓ Choices that affect architecture
✓ "Why" that needs preservation

✗ Minor implementation details
✗ Routine maintenance
✗ Configuration changes
✗ No real alternatives existed

-->
## [2026-03-31-174924] Markdown lint via podman, enforced by pre-commit hook

**Status**: Accepted

**Context**: No linting existed. Review found 65 markdown violations. User prefers containerized tools (podman over local install).

**Decision**: Markdown lint via podman, enforced by pre-commit hook

**Rationale**: Taskfile.yml with lint:md using podman run markdownlint-cli2 keeps deps isolated. Git pre-commit hook via .githooks/ ensures lint runs before any commit with markdown changes.

**Consequence**: All contributors need podman and task. Lint config (.markdownlint.yaml) disables MD013 (line-length) and MD060 (table-style) as too noisy for this project.

---

## [2026-03-31-174922] Docs live in docs/, not scattered at root

**Status**: Accepted

**Context**: Project had ctx-scaffolded placeholder files and specs/workflows at root level alongside the code

**Decision**: Docs live in docs/, not scattered at root

**Rationale**: Centralizing docs under docs/ reduces root clutter. Placeholder files with no swarm content were removed rather than maintained.

**Consequence**: Spec refs changed from specs/ to docs/specs/. Workflows moved to docs/workflows/. README and CLAUDE.md stay at root.

---

## [2026-03-31-154822] Skill lives in skill/ with symlinks for agent discovery

**Status**: Accepted

**Context**: Need the skill to be both the repo's product and installable by Claude Code and Codex without file copying

**Decision**: Skill lives in skill/ with symlinks for agent discovery

**Rationale**: Single source of truth in skill/swarm/SKILL.md. .claude/skills symlinks to skill/. Codex symlinks to skill/swarm/. No copying, no drift.

**Consequence**: Install instructions are ln -s commands. The repo's skill/ directory IS the skill. README documents both symlink paths.

---

## [2026-03-30-175519] Session mode is the only MVP, ephemeral mode deferred

**Status**: Accepted

**Context**: User feedback: the real workflow is Claude and Codex already open in tmux, needing to iterate on shared work. Ephemeral mode, CI positioning, and workflow-engine framing dilute the product.

**Decision**: Session mode is the only MVP, ephemeral mode deferred

**Rationale**: Optimizing for one happy path (2 panes, 2 agents, bootstrap, shared buffer, ping-pong, manual interrupt) produces a sharper, more differentiated tool. Power-user ergonomics matter more than manifest purity or broad CLI support.

**Consequence**: Ephemeral mode (swarm run, respawn-pane, file-based IPC) moves to future work. MVP scope shrinks to: session mode, task/parallel/sequence/pingpong primitives, shared/private buffers, bootstrap, auto+manual nudge, completion signaling. Key metric: under a minute from open tmux panes to productive agent iteration.

---

## [2026-03-30-173646] tmux named buffers as IPC

**Status**: Accepted

**Context**: Need a data flow mechanism for live agents in persistent tmux sessions

**Decision**: tmux named buffers as the primary IPC mechanism

**Rationale**: Session mode agents are live processes whose stdout cannot be redirected; buffers are visible to all panes, atomic via paste-buffer, and any agent that can run shell commands can read/write them.

**Consequence**: Practical size limits (~few MB per buffer); large outputs should write to files and pass paths through buffers instead of content.

---

## [2026-03-30-173642] Shell-based coordinator, no compiled binary

**Status**: Accepted

**Context**: Need to choose implementation language for the workflow coordinator

**Decision**: Shell-based coordinator, no compiled binary

**Rationale**: Zero dependencies beyond bash, tmux, yq, jq. Target audience already has these. Shell is the native language of tmux scripting. Users can inspect and modify the coordinator.

**Consequence**: Implementation is ~800 lines of bash across multiple files. No build step. May need to revisit if complexity grows beyond what shell handles well.

---

## [2026-03-30-173640] Two coordination modes: ephemeral and session

**Status**: Superseded by [2026-03-30-175519] Session mode is the only MVP

**Context**: Need to support both automated workflows (agents spawn/exit) and interactive collaboration (agents persist with loaded context, MCP, history)

**Decision**: Two coordination modes: ephemeral and session

**Rationale**: Ephemeral (respawn-pane + files + wait-for) is simpler for automation; session (send-keys + tmux buffers) preserves agent state needed for bootstrapped agents and human-in-the-loop collaboration. Both share the same workflow primitives.

**Consequence**: Two manifest formats (mode: ephemeral vs mode: session), two transport implementations, but unified primitive logic (parallel, sequence, pingpong, gate). Two CLI commands: swarm run and swarm session.
