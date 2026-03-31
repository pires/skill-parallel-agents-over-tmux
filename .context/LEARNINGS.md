# Learnings

<!--
UPDATE WHEN:
- Discover a gotcha, bug, or unexpected behavior
- Debugging reveals non-obvious root cause
- External dependency has quirks worth documenting
- "I wish I knew this earlier" moments
- Production incidents reveal gaps

DO NOT UPDATE FOR:
- Well-documented behavior (link to docs instead)
- Temporary workarounds (use TASKS.md for follow-up)
- Opinions without evidence
-->

<!-- INDEX:START -->
| Date | Learning |
|------|--------|
| 2026-03-31 | Use stable tmux pane IDs, not positional indices |
| 2026-03-31 | tmux pane targets depend on base-index config |
| 2026-03-31 | tmux display-message exit code unreliable for pane existence |
| 2026-03-31 | Clear completion signals before nudging, not after |
| 2026-03-31 | Background subshells must not prompt stdin |
| 2026-03-31 | Bash 3.2 on macOS lacks associative arrays |
<!-- INDEX:END -->

<!-- Add gotchas, tips, and lessons learned here -->
## [2026-03-31-005450] Use stable tmux pane IDs, not positional indices

**Context**: Live test failed because splitting a pane renumbered Codex from 1:3.2 to 1:3.3, so the coordinator nudged its own pane

**Lesson**: Positional pane targets like :1.2 shift when panes are added or removed. tmux stable pane IDs (%11, %12) are immutable and safe for targeting.

**Application**: Always use pane_id (%-prefixed) in manifests. Run the coordinator in a separate window, not a split in the agents window.

---

## [2026-03-31-004202] tmux pane targets depend on base-index config

**Context**: Integration tests and docs hardcoded :0.0/:0.1 but the test environment had base-index 1, causing pane targets to be :1.1/:1.2

**Lesson**: Pane targets like :0.0 are not portable. tmux base-index and pane-base-index config changes the numbering.

**Application**: Use tmux list-panes -F to discover actual targets. Never hardcode pane indices in tests or tooling.

---

## [2026-03-31-004159] tmux display-message exit code unreliable for pane existence

**Context**: Integration test passed validation for a nonexistent pane because tmux display-message -t returned exit 0 with empty output

**Lesson**: tmux display-message -t can return exit code 0 for nonexistent panes. Must check for non-empty output, not just exit status.

**Application**: In tmux_pane_exists, capture output and test -n, not just the return code.

---

## [2026-03-31-003309] Clear completion signals before nudging, not after

**Context**: A fast agent could signal done before the coordinator cleared the previous signal, causing false timeouts

**Lesson**: If completion signals (buffers, sentinel files) are cleared after sending a prompt, a fast agent can signal done before the clear runs, causing a false timeout.

**Application**: Always clear/reset signal state before the action that triggers the signal, not after.

---

## [2026-03-31-003308] Background subshells must not prompt stdin

**Context**: Parallel child tasks were calling read in background, stealing terminal input

**Lesson**: Background subshells that call read from stdin can steal terminal input, interleave prompts, or block.

**Application**: When backgrounding work that shares code with interactive paths, set SWARM_INTERACTIVE=false in the subshell and check it plus -t 0 before any read call.

---

## [2026-03-31-003306] Bash 3.2 on macOS lacks associative arrays

**Context**: Implementation failed at runtime on macOS because declare -A is Bash 4+

**Lesson**: macOS ships Bash 3.2 which does not support declare -A. Use parallel indexed arrays with lookup functions instead.

**Application**: Never use associative arrays in shell scripts targeting macOS. Use indexed arrays with a linear-scan lookup helper.
