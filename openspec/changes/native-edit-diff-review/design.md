## Context

`mcp-emacs` exposes an HTTP streamable MCP server (`mcp-emacs-server.el`, `http://localhost:<port>/mcp`) and, among its tools, `apply_diff` (`mcp-emacs.el`) which opens `ediff-buffers` (Buffer A = file, Buffer B = proposal), cooperatively polls a `result` cell, and returns `applied` / `rejected` / `timeout` from an explicit accept/reject action.

Claude Code treats an HTTP MCP server purely as a tool provider. Its built-in Edit/Write/MultiEdit tools never consult an MCP server; they write files directly. So `apply_diff` only fires when the model explicitly calls it — never on a native edit.

Claude Code *does* route native edits through a review step when it detects an **IDE**. The IDE integration is a separate channel from MCP:

1. The IDE runs a WebSocket server.
2. It writes a lockfile `~/.claude/ide/<port>.lock` containing `{pid, workspaceFolders, ideName, transport:"ws"}` (per claude-code-ide.el `claude-code-ide-mcp.el:176-201`).
3. Claude Code, launched inside that workspace, scans `~/.claude/ide/`, connects to the advertised port over WebSocket, and negotiates an MCP session over that socket.
4. When the IDE advertises an `openDiff` tool, Claude Code's native edit flow calls `openDiff` (old contents vs new contents, a tab name) and only writes if the IDE returns an "applied/saved" result; it later issues `close_tab` / `closeAllDiffTabs`.

The gap: `mcp-emacs` speaks only HTTP MCP and publishes no lockfile, so it is never seen as an IDE, so native edits bypass ediff.

## Goals / Non-Goals

**Goals:**
- Claude Code discovers a running Emacs as an IDE for the current workspace.
- Native Edit/Write/MultiEdit route through an interactive ediff review before the file is written.
- Reuse the existing `apply_diff` accept/reject ediff flow for the review UI.
- Keep the HTTP MCP server and `apply_diff` working unchanged; the IDE surface is additive and opt-in.

**Non-Goals:**
- Not replacing the HTTP MCP transport with WebSocket for the existing tools.
- Not implementing the full Claude Code IDE tool set (selection sync, diagnostics push, at-mention, etc.) — only what native-edit diff review requires (`openDiff`, `close_tab`, `closeAllDiffTabs`). Other IDE tools are future work.
- Not auto-saving beyond what the accept path already does; the return contract to Claude Code (`FILE_SAVED`) governs whether Claude Code itself writes.

## Decisions

### D1: A separate IDE-protocol server module, additive to the HTTP server
Add a new module (e.g. `mcp-emacs-ide.el`) owning the WebSocket server, the lockfile lifecycle, and the IDE tool handlers. It does not touch `mcp-emacs-server.el`. Rationale: the IDE protocol is unofficial and may break independently; isolating it keeps the stable HTTP path unaffected and lets the surface be toggled off.

### D2: Reuse the `apply_diff` ediff flow for `openDiff`
`openDiff` receives `old_file_contents` / `new_file_contents` / `tab_name`. Drive the same ediff accept/reject session `apply_diff` already implements (Buffer A = old/current, Buffer B = new), reusing its cooperative-poll `result` cell and accept/reject commands. Map the outcome to Claude Code's contract:
- accept → `FILE_SAVED` (and apply the accepted content),
- reject → `DIFF_REJECTED`,
- timeout → treat as reject (`DIFF_REJECTED`), consistent with "did not accept."

Rationale: the review UX is already built and tested; only the transport and result-string mapping are new. Factor the ediff-session core out of `mcp-emacs-apply-diff` so both callers share it.

### D3: Lockfile lifecycle tied to IDE-server start/stop
On IDE-server start: pick/confirm a port, write `~/.claude/ide/<port>.lock` with `pid`, `workspaceFolders` (the project root), `ideName` ("Emacs"), `transport` ("ws"). On stop / Emacs kill: remove the lockfile. Rationale: matches the discovery contract Claude Code expects; stale lockfiles must not linger.

### D4: WebSocket transport via `websocket.el`
The IDE transport is `ws`; the current HTTP server cannot serve it. Depend on `websocket.el` (load lazily; error with an install hint when the IDE surface is enabled but the package is missing, mirroring the existing optional-feature pattern in the codebase). Rationale: reuse a maintained WS implementation rather than hand-rolling framing.

### D5: Opt-in, off by default
Gate the IDE surface behind an explicit enable (defcustom / command), off by default. Rationale: the protocol is reverse-engineered and version-fragile; users retiring claude-code-ide opt in deliberately, and a protocol break never affects users who only use the HTTP MCP tools.

## Risks / Trade-offs

- **[Unofficial, undocumented protocol]** Claude Code's IDE WebSocket handshake and tool schemas are reverse-engineered from claude-code-ide.el and may change without notice → isolate in its own module (D1), opt-in (D5), and pin behaviour against a known-good Claude Code version; document the version verified against.
- **[Lockfile collision with claude-code-ide.el]** If both are enabled they both write to `~/.claude/ide/` → during transition, run only one IDE provider per workspace; document this. (Retiring claude-code-ide is the point.)
- **[Two servers, one project]** HTTP MCP + IDE WS for the same workspace → verify Claude Code tolerates both a configured MCP server and an IDE connection simultaneously; if it double-loads tools, keep the IDE surface's advertised tool set minimal (diff tools only) to avoid duplicate tool names.
- **[Stale lockfile after crash]** Emacs killed without cleanup leaves a `.lock` pointing at a dead pid → include `pid` (already in schema) so a future Claude Code / cleanup can detect staleness; best-effort remove on `kill-emacs-hook`.
- **[WebSocket dependency]** New `websocket.el` requirement → lazy-load and fail with a clear install hint only when the IDE surface is enabled.

## Migration Plan

Purely additive and opt-in. No change to existing tools or transport. Rollback = disable the IDE surface (or revert the module); the HTTP MCP server and `apply_diff` are untouched. During transition, disable claude-code-ide.el for the workspace before enabling this to avoid two IDE lockfiles.

## Open Questions

- Exact WebSocket handshake / MCP-over-ws framing Claude Code expects (subprotocol, initial `initialize` params, auth token if any) — nail down against a live Claude Code, using claude-code-ide.el's `claude-code-ide-mcp-http-server.el` as the reference.
- Precise result strings Claude Code accepts from `openDiff` (`FILE_SAVED` / `DIFF_REJECTED` observed in claude-code-ide.el) and whether Claude Code writes the file itself on `FILE_SAVED` or expects the IDE to have saved it.
- Whether `openDiff` must return the (possibly human-edited) final content, or only a status — determines whether the human's in-ediff edits propagate back to Claude Code.
- Which Claude Code version(s) to pin/verify against, and where to record that.
