## Why

Today the AI harness only sees a human's edits to the shared Org task file when it chooses to poll (`org_task_session`).
There is no way for the human's change to reach the AI without the AI re-reading on its own initiative.
Claude Code exposes no inbound API, so an interrupt-style push is impossible — but a *cooperative loop* is: the AI can call a tool that waits until the human edits, then wakes with the change.
This turns the shared file into a real back-and-forth workspace where the AI works, then waits for the human's next direction.

## What Changes

- Add a blocking-with-timeout MCP tool `org_task_wait_for_change` that returns when the session task file changes (buffer edited) or a timeout elapses.
- The wait MUST NOT freeze Emacs: it yields to the event loop while waiting, so human edits and other tool calls still process during the wait.
- Change detection is relative to a baseline the caller can establish, so edits made between reads are not missed (not only edits during the wait window).
- On wake, the tool returns whether a change occurred and the current session view (task, session id, status, TODO checklist), so the AI can react without a second call.
- On timeout with no change, the tool returns a defined "no change" result rather than an error.

## Capabilities

### New Capabilities
- `org-task-wait`: A cooperative-loop MCP tool that blocks (up to a timeout, without freezing Emacs) until the session task file is edited, then returns the change status and current session view. Covers change detection relative to a baseline and event-loop-friendly waiting.

### Modified Capabilities
<!-- None. org-task-session (read) and org-task-update (mutate) are unchanged. -->

## Impact

- **Code**: new `mcp-emacs-*` helper in `elisp/mcp-emacs.el` (wait loop + change detection); new tool plist in `mcp-emacs-server--tools`.
- **APIs**: adds one MCP tool; existing tools/resources unchanged.
- **Concurrency**: relies on `accept-process-output`/`sit-for` to yield the single-threaded event loop while waiting; change detection via buffer modification tick or a change hook.
- **Dependencies**: built-in Emacs only.
- **Harness fit**: cooperative (AI opts to wait); does not attempt to interrupt a running turn, which Claude Code cannot support.
