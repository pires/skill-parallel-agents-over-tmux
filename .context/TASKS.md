# Tasks

<!--
UPDATE WHEN:
- New work is identified → add task with #added timestamp
- Starting work → add #in-progress or #started timestamp
- Work completes → mark [x] with #done timestamp
- Work is blocked → add to Blocked section with reason
- Scope changes → update task description inline

DO NOT UPDATE FOR:
- Reorganizing or moving tasks (violates CONSTITUTION)
- Removing completed tasks (use ctx task archive instead)

STRUCTURE RULES (see CONSTITUTION.md):
- Tasks stay in their Phase section permanently: never move them
- Use inline labels: #in-progress, #blocked, #priority:high
- Mark completed: [x], skipped: [-] (with reason)
- Never delete tasks, never remove Phase headers

TASK STATUS LABELS:
  `[ ]`: pending
  `[x]`: completed
  `[-]`: skipped (with reason)
  `#in-progress`: currently being worked on (add inline, don't move task)
-->

### Phase 0: Design `#priority:high`
Spec: `docs/specs/swarm-design.md`
- [x] Brainstorm architecture and workflow primitives #done:2026-03-30-154800
- [x] Write spec document #done:2026-03-30-154800
- [x] Write README with quickstarts #done:2026-03-30-154800
- [x] Narrow scope to session-mode-only MVP #done:2026-03-30-155500
- [x] External review of spec (Codex) #added:2026-03-30-154800 #done:2026-03-31-120000

### Phase 1: Core Infrastructure `#priority:high`
Spec: `docs/specs/swarm-design.md`
- [x] Scaffold file layout (bin/, lib/, lib/primitives/, lib/utils/) #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement `lib/tmux.sh` — buffer ops, send-keys, pane management #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement `lib/utils/logging.sh` — timestamped event logging #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement `lib/utils/templates.sh` — `{{buffer:X}}`, `{{agent}}` resolution #added:2026-03-30-155500 #done:2026-03-31-120000

### Phase 2: Session Mode `#priority:high`
Spec: `docs/specs/swarm-design.md`
- [x] Implement `lib/primitives/task.sh` — single agent nudge + wait for completion #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement `lib/primitives/parallel.sh` — concurrent nudge + collect #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement `lib/primitives/sequence.sh` — ordered steps with output threading #added:2026-03-30-160000 #done:2026-03-31-120000
- [x] Implement `lib/primitives/pingpong.sh` — iteration loop with shared buffer #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement `lib/coordinator.sh` — parse manifest, orchestrate session workflow #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement bootstrap (send commands to panes, wait bootstrap_delay seconds) #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement completion signaling (buffer-based polling + file sentinel fallback) #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement auto and manual nudge modes #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Implement pane activity detection (hold nudge if human is typing) #added:2026-03-30-160000 #done:2026-03-31-120000
- [x] Implement timeout handling (default 5m per step, report and prompt on expiry) #added:2026-03-30-160500 #done:2026-03-31-120000
- [x] Wire `bin/swarm` entry point #added:2026-03-30-155500 #done:2026-03-31-120000
- [x] Test with Claude + Codex ping-pong session (Claude iteration works, Codex handoff not yet verified end-to-end) #added:2026-03-30-155500 #started:2026-03-31-010000 #done:2026-03-31-150000

### Phase 3: Polish `#priority:medium`
Spec: `docs/specs/swarm-design.md`
- [x] Write example workflows (brainstorm-review, code-review) #added:2026-03-30-155500 #done:2026-03-31-013000
- [ ] Mid-flight pause via swarm-control buffer #added:2026-03-30-155500

## Blocked
