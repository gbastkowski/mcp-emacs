## Why

`claude-code-ide.el` offers useful editor-integration features — an interactive
diff/apply flow and editor-state queries — but ships them behind the
Claude-Code-CLI-specific "IDE" WebSocket protocol (lockfile handshake,
`CLAUDE_CODE_SSE_PORT`/`ENABLE_IDE_INTEGRATION` env vars).
`mcp-emacs` already exposes Emacs to any MCP client over plain HTTP, so the
pull-model subset of those features can live here instead and work with any
harness, removing the need for a second, CLI-bound package.

## What Changes

- Add an `apply_diff` MCP tool: given a file path and proposed new content, open
  an `ediff` session (original vs proposed), let the human edit, accept, or
  reject the proposal interactively, then return the final content and a status
  of `applied`, `rejected`, or `timeout`.
- The `apply_diff` handler blocks cooperatively using the existing
  `accept-process-output` wait pattern (as in `org_task_wait_for_change`), so
  the single-threaded server keeps processing other tool calls and edits while
  it waits, and it honours a bounded timeout.
- Add a `list_open_editors` MCP tool: return the live file-visiting buffers
  (path, buffer name, modified flag).
- Add a `check_document_dirty` MCP tool: report whether a given file's buffer
  has unsaved changes.
- Out of scope (not harness-agnostic): the Claude-Code-CLI IDE WebSocket
  protocol, the lockfile/env-var handshake, the terminal runner, and live
  selection/at-mention push notifications.
- No new tools for capabilities already covered: `open_file`, `get_selection`,
  and `save_buffer` already exist and are reused.

## Capabilities

### New Capabilities
- `ide-integration-tools`: harness-agnostic, pull-model editor-integration MCP
  tools — an interactive `ediff`-based diff/apply flow and editor-state queries
  (open editors, document dirty state).

### Modified Capabilities
<!-- None. Existing specs cover only org-task features; these tools are new and independent. -->

## Impact

- `elisp/mcp-emacs.el`: new helper functions (`apply_diff` ediff orchestration
  and blocking wait, open-editors listing, dirty check).
- `elisp/mcp-emacs-server.el`: register the three new tool descriptors
  (`:name`, `:description`, `:schema`, `:handler`).
- Plugin/skill surface: `apply_diff` becomes available to `review-diagnostics`
  and `edit-at-point` workflows; docs (`README.md`, skills) mention it.
- No new package dependencies — `ediff` is built in; reuses the existing wait
  infrastructure and timeout customization.
- No breaking changes; purely additive.
