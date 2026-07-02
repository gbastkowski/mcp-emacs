## Why

AI coding harnesses (Claude Code, opencode, etc.) tend to degrade the human into a passive reviewer of generated diffs.
There is no shared, live workspace where the human and the AI collaborate on the plan itself.
An Org file — the human's native planning surface in Emacs — can become that shared workspace: the AI reports status into it while the human concurrently reshapes, reprioritizes, or adds tasks, keeping the human in the driver's seat.

## What Changes

- Introduce an MCP capability for a **session-scoped Org task file**: one Org file holding a top-level task, a TODO checklist, and an assigned session identifier.
- New MCP tools let an AI harness:
  - read the current task file (task heading, TODO list, session, status) as structured text;
  - update the status of the session and of individual TODO items (e.g. mark done, in-progress, blocked);
  - append progress notes / a status line to the task without clobbering human edits.
- The human keeps editing the same Org file live in Emacs; AI writes go through Emacs (via the running MCP server) so buffer state and human edits are respected rather than overwritten from disk.
- The AI MUST NOT reorder, delete, or rewrite human-authored TODO items it did not create; it only updates status of known items and appends new ones.

## Capabilities

### New Capabilities
- `org-task-session`: A session-scoped Org task file (task heading + TODO checklist + session id + status) that an AI harness reads and updates while the human edits it concurrently in Emacs. Covers locating/resolving the active session task file and exposing its contents as structured, read-friendly text.
- `org-task-update`: Mutating MCP tools for the AI harness to update session status, update the status of individual TODO items, and append progress notes to the session task file — without overwriting concurrent human edits.

### Modified Capabilities
<!-- None. Existing current-clocked-task / current-task-at-point specs are unaffected. -->

## Impact

- **Code**: new `mcp-emacs-*` helpers in `elisp/mcp-emacs.el`; new tool plists in the `mcp-emacs-server--tools` registry in `elisp/mcp-emacs-server.el`.
- **APIs**: adds MCP tools (read + mutate) for the org task session; no changes to existing tools/resources.
- **Dependencies**: relies on built-in `org-mode` / `org-element`; no new external deps.
- **Concurrency**: writes must go through the live Emacs buffer to interleave safely with human edits (aligned with existing "write through Emacs, not disk" architecture).
