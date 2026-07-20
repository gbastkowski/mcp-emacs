## Context

`mcp-emacs-explain-selection-in-current-session` guards with `(unless (mcp-emacs-run--live-buffer root) (user-error ...))` before routing. That guard is correct for the TUI branch but wrong for the headless branch, which is a standalone `claude -p` call needing no session.

## Goals / Non-Goals

**Goals:**
- Let explain work with no session by falling through to the headless popup path.

**Non-Goals:**
- No launching of a hidden TUI session (one-shot headless, no continuity).
- No change to the headless query or popup primitive.

## Decisions

### Decision: gate only the TUI branch on visibility, drop the blanket guard
Remove the top-level `user-error`. Route: `session-visible-p` → TUI send; else → headless popup. `--session-visible-p` already returns nil for both hidden and absent sessions, so the else-branch naturally covers "no session".

## Risks / Trade-offs

- [Headless call may prompt for permissions in an unfamiliar project] → explain needs no tools, so a `-p` run should not trigger tool prompts; out of scope otherwise.

## Open Questions

- None.
