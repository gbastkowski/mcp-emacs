## Why

`mcp-emacs` already has an interactive `apply_diff` tool that opens ediff and blocks until the human accepts or rejects (see the archived `explicit-diff-accept` change).
But `apply_diff` is a plain MCP tool: Claude Code only invokes it when the model explicitly chooses to.
Claude Code's *native* Edit / Write / MultiEdit operations never route through it — they write to disk directly, with no in-editor review.

claude-code-ide.el gets automatic diff review because it does not register as an ordinary MCP server.
It registers as an **IDE**: a WebSocket server (subprotocol `mcp`), plus it **launches the Claude Code CLI itself** with `CLAUDE_CODE_SSE_PORT=<port>` and `ENABLE_IDE_INTEGRATION=true` in the environment.
The CLI reads those env vars and connects back to `ws://127.0.0.1:<port>` as an IDE client; its built-in edit flow then calls the IDE-side `openDiff` tool before writing any file.
(A `~/.claude/ide/<port>.lock` file is also written, but the spike found the env vars are what actually drive this CLI's connection — see spike-findings.md.)
The diff review is a property of being the *IDE that spawned the CLI*, not of exposing a tool named `openDiff`.

Because `mcp-emacs` speaks only streamable-HTTP MCP, it cannot participate in that flow.
This is the largest UX gap blocking retirement of claude-code-ide.el (#10).

## What Changes

- Add an **IDE-protocol integration surface** to `mcp-emacs`, alongside the existing HTTP MCP server, so Claude Code discovers Emacs as an IDE and routes native file edits through an in-editor diff review.
  - Run a WebSocket server (subprotocol `mcp`) that speaks Claude Code's IDE MCP-over-WebSocket protocol (JSON-RPC 2.0; `initialize`/`tools/list`/`tools/call`, protocol version `2024-11-05`).
  - Launch the Claude Code CLI from mcp-emacs with `CLAUDE_CODE_SSE_PORT=<port>` and `ENABLE_IDE_INTEGRATION=true` so it connects to that WS server (extends the existing claude-runner). Also publish `~/.claude/ide/<port>.lock` (`{pid, workspaceFolders, ideName, transport:"ws"}`) and remove it on shutdown.
  - Implement the IDE-side diff tools Claude Code calls during native edits: `openDiff`, `close_tab`, and `closeAllDiffTabs`, using the protocol's **deferred**-response mechanism so the socket isn't blocked during human review.
  - Reuse the existing ediff accept/reject flow from `apply_diff` for the `openDiff` review; on resolution complete the deferred call with `FILE_SAVED` + final content (accept) or `DIFF_REJECTED` + tab name (reject).
- Keep the existing HTTP MCP server and `apply_diff` unchanged; the IDE surface is additive and independently toggleable.

## Capabilities

### New Capabilities
- `ide-protocol-integration`: register `mcp-emacs` as a Claude Code IDE (lockfile discovery + WebSocket transport) and serve the diff tools that native edits invoke, so Claude Code's built-in Edit/Write flow shows an interactive ediff review before writing.

### Modified Capabilities
<!-- none: the existing HTTP `apply_diff` flow (ide-integration-tools) is unchanged and reused. -->

## Impact

- New elisp: an IDE-protocol server module (WebSocket transport, deferred-response handling, lockfile lifecycle, `openDiff`/`close_tab`/`closeAllDiffTabs` handlers).
- New dependency: a WebSocket implementation (e.g. `websocket.el`); the current HTTP server does not speak `ws`.
- **Runner dependency**: mcp-emacs must launch Claude Code with the IDE env vars — a Claude Code started independently won't connect. This ties #10 to the existing claude-runner work (see [[replace-claude-code-ide-goal]] — the runner is the blocker).
- Reuses `mcp-emacs.el`'s ediff accept/reject plumbing; no change to `apply_diff` itself.
- Lifecycle: IDE server start/stop must create and remove the `~/.claude/ide/*.lock` file, and should coexist with the HTTP MCP server for the same project.
- **Risk / unofficial protocol**: Claude Code's IDE transport is undocumented and reverse-engineered; it may break across Claude Code releases. Gate the surface behind an explicit opt-in so a protocol change never destabilises the HTTP server.
- Closes #10.
