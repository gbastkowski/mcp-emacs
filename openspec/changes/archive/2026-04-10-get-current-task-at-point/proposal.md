## Why

The server can now expose the currently clocked Org task, but it still has no dedicated way to ask which task is at the current point in the active buffer.
Adding that capability closes a nearby gap for agents and users who need point-scoped Org task context rather than global clock state.

## What Changes

- Add a new tool for retrieving the current task at point from Emacs.
- Define the expected behavior when point is on or within an Org task heading or subtree, including returning the task text in a stable, user-facing form.
- Define the expected behavior when point is not on an Org task, including a friendly fallback response instead of a raw error or nil.
- Distinguish the new point-scoped capability from the existing current-clocked-task capability so the MCP surface stays clear and predictable.

## Capabilities

### New Capabilities
- `current-task-at-point`: Retrieve the Org task at the current point in Emacs, with a predictable fallback when point is not on an Org task.

### Modified Capabilities
- None.

## Impact

- Affected code will likely include the tool registration layer in `src/tools/`, the Emacs client integration path, and the Emacs Lisp helper definitions in `elisp/mcp-emacs.el` and generated bootstrap output.
- The MCP API surface will gain a new read-only operation for point-scoped Org task lookup.
- Tests will likely need to cover both task-at-point and no-task-at-point cases using the existing tool test pattern.
