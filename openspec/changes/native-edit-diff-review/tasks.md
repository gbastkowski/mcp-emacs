## 1. Protocol spike (verify against live Claude Code)

- [ ] 1.1 Using claude-code-ide.el as reference, confirm the `~/.claude/ide/<port>.lock` schema Claude Code actually reads (`pid`, `workspaceFolders`, `ideName`, `transport`).
- [ ] 1.2 Capture the WebSocket handshake Claude Code performs: connect target, subprotocol, and the `initialize` / tool-negotiation messages over the socket.
- [ ] 1.3 Record the `openDiff` argument shape (`old_file_contents`, `new_file_contents`, `tab_name` or equivalent) and the exact result strings Claude Code honours (`FILE_SAVED` / `DIFF_REJECTED`).
- [ ] 1.4 Note the Claude Code version verified against; write it into design.md's Open Questions resolution.

## 2. IDE-protocol server module

- [ ] 2.1 Add `mcp-emacs-ide.el` (new module) with a WebSocket server via `websocket.el`, lazy-loaded with an install-hint error when the IDE surface is enabled but the package is absent.
- [ ] 2.2 Implement MCP-over-WebSocket session negotiation matching the spike findings (initialize, tool list = diff tools only).
- [ ] 2.3 Lifecycle commands: `mcp-emacs-ide-start` / `mcp-emacs-ide-stop`, off by default behind a defcustom opt-in.

## 3. Discovery lockfile

- [ ] 3.1 On IDE-server start, write `~/.claude/ide/<port>.lock` with `pid`, `workspaceFolders` (project root), `ideName` "Emacs", `transport` "ws".
- [ ] 3.2 Remove the lockfile on `mcp-emacs-ide-stop` and best-effort on `kill-emacs-hook`.

## 4. Diff tools reusing the ediff flow

- [ ] 4.1 Factor the ediff accept/reject session core out of `mcp-emacs-apply-diff` into a shared function (Buffer A = old, Buffer B = new; cooperative poll; explicit accept/reject; timeout) without changing `apply_diff` behaviour.
- [ ] 4.2 `openDiff`: drive the shared ediff flow; accept → `FILE_SAVED` (apply accepted content), reject → `DIFF_REJECTED`, timeout → `DIFF_REJECTED`.
- [ ] 4.3 `close_tab` and `closeAllDiffTabs`: tear down the ediff session(s) for the named tab / all tabs and clean up buffers.
- [ ] 4.4 Track active diff sessions by tab name so `close_tab` can target the right one.

## 5. Coexistence & lifecycle

- [ ] 5.1 Verify the IDE WS surface and the HTTP MCP server run together for the same project without tool-name or port conflicts.
- [ ] 5.2 Confirm no stale lockfile remains after a normal stop; document the crash-stale case.

## 6. Tests

- [ ] 6.1 Lockfile written on start with the expected schema; removed on stop.
- [ ] 6.2 Shared ediff-flow unit tests still cover accept / reject / edit-then-accept / quit (regression parity with `apply_diff`).
- [ ] 6.3 `openDiff` maps accept → `FILE_SAVED`, reject/timeout → `DIFF_REJECTED` (drive the bound commands headlessly, as the existing apply-diff tests do).
- [ ] 6.4 `close_tab` / `closeAllDiffTabs` clean up their sessions and buffers.

## 7. Docs & checks

- [ ] 7.1 README: document the IDE surface, the opt-in, the `websocket.el` dependency, and the "disable claude-code-ide first" transition note.
- [ ] 7.2 Record the verified Claude Code version and the unofficial-protocol caveat.
- [ ] 7.3 Byte-compile clean; all tests pass.
- [ ] 7.4 Verify live: with the IDE surface enabled, a native Claude Code Edit opens ediff; accept writes the file, reject leaves it unchanged.
