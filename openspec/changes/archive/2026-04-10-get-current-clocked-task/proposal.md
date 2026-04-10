## Why

The server can already expose several pieces of Emacs state, but it does not yet provide a dedicated way to ask for the task currently clocked in via Org mode.
Adding that capability closes a practical gap for agents and users who need lightweight access to the active task without inspecting broader Org data.

## What Changes

- Add a new capability for retrieving Emacs' currently clocked in task.
- Define the expected behavior when a task is clocked in, including returning the current task text in a stable, user-facing form.
- Define the expected behavior when no task is clocked in, including a friendly fallback response instead of an error.
- Specify the impact on the MCP surface so the new capability can be exposed consistently with existing tool patterns.

## Capabilities

### New Capabilities
- `current-clocked-task`: Retrieve the Org task currently clocked in from Emacs, with a predictable fallback when no clock is active.

### Modified Capabilities
- None.

## Impact

- Affected code will likely include the tool registration layer in `src/tools/`, the Emacs client integration path, and the Emacs Lisp helper definitions in `elisp/mcp-emacs.el` and generated bootstrap output.
- The MCP API surface will gain a new read-only operation for current Org clock state.
- Tests will likely need to cover both clocked-in and not-clocked-in cases using the existing tool test pattern.
