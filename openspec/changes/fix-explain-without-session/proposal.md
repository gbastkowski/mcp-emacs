## Why

Explain-selection currently errors with "No live runner session for this project" when there is no session, even though the non-visible path uses a standalone headless `claude -p` call that needs no session at all. The live-session requirement should only apply to the TUI path.

## What Changes

- Explain-selection no longer requires a live session. It routes as:
  - session buffer visible in a window → send the explain request to that live TUI session (unchanged);
  - otherwise (no session, or session hidden) → fetch the explanation with a one-shot headless query and render it in the popup output window.
- The only case that still needs a session is the TUI path, which only applies when a session buffer is already visible.

## Capabilities

### New Capabilities

### Modified Capabilities
- `runner-send-prompt`: the explain-selection requirement drops the blanket live-session requirement; the headless popup path works with no session.

## Impact

- `elisp/mcp-emacs-run.el` — remove the top-level session guard in `mcp-emacs-explain-selection-in-current-session`; keep the TUI branch gated on session visibility.
- Tests updated: no-session now routes to headless popup rather than erroring.
- No MCP tool surface change.
