## Why

`mcp-emacs` now exposes the pull-model editor tools Claude needs (buffers, Org,
xref, diagnostics, diff/apply, project/workspace) over plain MCP. The one thing
it cannot do — and the last reason `claude-code-ide.el` is still installed — is
**run** Claude: launch and manage the Claude Code CLI inside Emacs. Adding a
runner lets Claude connect to those editor tools through `mcp-emacs` over MCP
instead of the proprietary IDE WebSocket protocol, clearing the path to retire
`claude-code-ide.el`.

## What Changes

- Add a new file `elisp/mcp-emacs-run.el` (kept separate from the MCP server so
  the server stays a pure MCP server).
- Use **eat** as the terminal backend: the Claude CLI is a full-screen ANSI TUI
  that needs a real terminal emulator, not a comint line-mode; eat is pure
  Elisp (no hard C dependency), rewraps on resize, and flickers less. eat is a
  soft/optional dependency, loaded when present, matching `mcp-emacs`'s
  dependency-light design.
- **Launch**: start the `claude` CLI in an eat terminal buffer, project-aware
  (cwd = project root via `project.el`), so it connects to editor tools through
  `mcp-emacs` over MCP.
- **Session management**: per-project named sessions with buffer names like
  `*claude:<project>*`; commands to list, switch, and kill sessions.
- **Window management**: toggle / show / hide the Claude window, with
  side-window placement and focus control.
- **Continue/resume**: support `claude --continue` and `claude --resume` for
  prior conversations.
- The `claude` executable path and extra CLI flags are customizable.
- Out of scope: the IDE WebSocket protocol and its push notifications
  (`selection_changed` / `at_mentioned`) are intentionally dropped; editor
  integration is entirely via `mcp-emacs` MCP tools.

## Capabilities

### New Capabilities
- `claude-runner`: launch and manage the Claude Code CLI inside Emacs on an eat
  terminal — project-aware launch, per-project sessions, window management, and
  continue/resume — with editor integration provided over MCP rather than the
  IDE WebSocket protocol.

### Modified Capabilities
<!-- None. This is an additive, standalone capability in a new file. -->

## Impact

- New file `elisp/mcp-emacs-run.el`; no changes to `mcp-emacs.el` or
  `mcp-emacs-server.el`.
- New customizations: `claude` executable path, extra CLI flags, window
  placement.
- Docs: `README.md` gains a runner section; a follow-up (not this change) can
  drop `claude-code-ide` from the Doom config once the runner is proven.
- Dependencies: eat is used opportunistically (`featurep`/soft require); no new
  hard package dependency. `project.el` is built in.
- No breaking changes to existing tools; purely additive.
