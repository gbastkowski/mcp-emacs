## 1. Protocol spike (from claude-code-ide.el reference) — see spike-findings.md

- [x] 1.1 Lockfile schema confirmed: `~/.claude/ide/<port>.lock` = `{pid, workspaceFolders, ideName:"Emacs", transport:"ws"}`, no auth token.
- [x] 1.2 Transport confirmed: `websocket.el` server on `127.0.0.1`, subprotocol `mcp`, JSON-RPC 2.0; methods `initialize` (protocolVersion `2024-11-05`), `tools/list`, `tools/call`, `prompts/list`; `notifications/tools/list_changed` sent after init.
- [x] 1.3 `openDiff` args = `old_file_path`, `new_file_path`, `new_file_contents`, `tab_name`; deferred response — accept → `FILE_SAVED` + final content, reject → `DIFF_REJECTED` + tab_name; also `close_tab`/`closeAllDiffTabs`.
- [x] 1.4 **KEY**: discovery is push-by-env — Claude CLI is launched with `CLAUDE_CODE_SSE_PORT=<port>` + `ENABLE_IDE_INTEGRATION=true`; it connects to `ws://127.0.0.1:<port>`. Lockfile is secondary. → mcp-emacs must *run* Claude Code (runner dependency).
- [x] 1.5 Live-verified against Claude Code **v2.1.212** (2026-07-28): env-var launch connects (interactive only), handshake, `openDiff` args, and `FILE_SAVED`/`DIFF_REJECTED` accept/reject all confirmed. Findings recorded in spike-findings.md. Drift found — see 1.6.
- [x] 1.6 Record live-only findings that change the design: protocolVersion is **`2025-11-25`** (not `2024-11-05`); **`-p` headless does NOT connect** — runner must be interactive; Claude shows a **trust prompt** the runner must handle; **every `tools/call` must be answered or Claude blocks** — before each edit Claude calls `closeAllDiffTabs`+`getDiagnostics` then `openDiff`, so those two must be implemented/stubbed; new `ide_connected` notification.

## 2. IDE-protocol server module

- [x] 2.1 Add `mcp-emacs-ide.el` (new module) with a WebSocket server via `websocket.el`, lazy-loaded with an install-hint error when the IDE surface is enabled but the package is absent.
- [x] 2.2 Implement MCP-over-WebSocket session negotiation matching the spike findings (initialize, tool list = diff tools only).
- [x] 2.3 Lifecycle commands: `mcp-emacs-ide-start` / `mcp-emacs-ide-stop`, off by default behind a defcustom opt-in.

## 3. Discovery: env-injecting runner + lockfile

- [x] 3.1 Launch Claude Code from mcp-emacs with `CLAUDE_CODE_SSE_PORT=<port>` and `ENABLE_IDE_INTEGRATION=true` in its environment so it connects to the IDE WS server. **Must be interactive** (a TTY/eat buffer) — `-p` headless does not connect. Extends `mcp-emacs-run.el` (already uses `eat-make`); inject the env vars there.
- [x] 3.1a Trust prompt: **documented** (README) as a one-time manual Enter on first launch in a project. Auto-confirm/pre-trust deferred — claude has no trust flag and pre-seeding `~/.claude.json` is invasive; revisit if it proves annoying.
- [x] 3.2 On IDE-server start, write `~/.claude/ide/<port>.lock` with `pid`, `workspaceFolders` (project root), `ideName` "Emacs", `transport` "ws".
- [x] 3.3 Remove the lockfile on `mcp-emacs-ide-stop` and best-effort on `kill-emacs-hook`.

## 4. Diff tools reusing the ediff flow

- [x] 4.1 Factor the ediff accept/reject session core out of `mcp-emacs-apply-diff` into a shared function (Buffer A = old, Buffer B = new; cooperative poll; explicit accept/reject; timeout) without changing `apply_diff` behaviour.
- [x] 4.2 `openDiff`: drive the shared ediff flow; accept → `FILE_SAVED` (apply accepted content), reject → `DIFF_REJECTED`, timeout → `DIFF_REJECTED`.
- [x] 4.3 `close_tab` and `closeAllDiffTabs`: tear down the ediff session(s) for the named tab / all tabs and clean up buffers. **Required, not optional** — Claude calls `closeAllDiffTabs` before every edit and blocks until answered.
- [x] 4.4 Track active diff sessions by tab name so `close_tab` can target the right one. `tab_name` is Claude-generated and opaque (e.g. `"✻ [Claude Code] hello.txt (61e49d) ⧉"`) — echo it back verbatim on reject.
- [x] 4.5 `getDiagnostics`: implement/stub (accepts `{}` and `{uri:"file://…"}`). Claude calls it before and after every edit and blocks until answered; can return an empty diagnostics result initially (a full impl could wire Flycheck/Flymake later).
- [x] 4.6 Answer **every** `tools/call` — an unanswered call stalls the whole edit. `initialize` must echo protocolVersion `2025-11-25`.

## 5. Coexistence & lifecycle

- [x] 5.1 IDE WS server (random port 10000-65535) and the HTTP MCP server (own port) use independent ports and tool sets; no conflict. Live end-to-end run connected Claude Code to the IDE server while the HTTP server config was untouched.
- [x] 5.2 Confirmed: `mcp-emacs-ide-stop` removes the lockfile (verified live — `40386.lock` gone after stop). Crash-stale case: a hard Emacs kill leaves a `.lock` with a dead `pid`; `kill-emacs-hook` handles normal exit, and the `pid` field lets a future cleanup detect staleness.

## 6. Tests

- [x] 6.1 Lockfile written on start with the expected schema; removed on stop.
- [x] 6.2 Shared ediff-flow unit tests still cover accept / reject / edit-then-accept / quit (regression parity with `apply_diff`).
- [x] 6.3 `openDiff` maps accept → `FILE_SAVED`, reject/timeout → `DIFF_REJECTED` (drive the bound commands headlessly, as the existing apply-diff tests do).
- [x] 6.4 `close_tab` / `closeAllDiffTabs` clean up their sessions and buffers.

## 6a. Follow-up (ediff window setup)

- [x] 6a.1a Applied the fix in `mcp-emacs--ediff-review`: delete side windows (Treemacs etc.) and force `ediff-setup-windows-plain` + `split-window-horizontally` before `ediff-buffers`, with a per-tab `ediff-control-buffer-suffix`. Mirrors claude-code-ide's handler. Byte-compiles clean; both test suites still green.
- [ ] 6a.1b Re-verify live inside a real runner session that the ediff control + diff windows now open and accept/reject drive the file write. (Deferred to next session — resume from here.)

## 7. Docs & checks

- [x] 7.1 README: document the IDE surface, the opt-in, the `websocket.el` dependency, and the "disable claude-code-ide first" transition note.
- [x] 7.2 Record the verified Claude Code version and the unofficial-protocol caveat.
- [x] 7.3 Byte-compile clean (new files: no warnings); apply-diff tests 9/9 and IDE tests 20/20 pass.
- [x] 7.4 Verified live with the real module (Claude Code 2.1.212): env-launched Claude connected to `mcp-emacs-ide`, called closeAllDiffTabs/getDiagnostics/openDiff (all answered), openDiff registered as deferred, and completing it with `FILE_SAVED`+content drove Claude to apply the edit (`line one`→`HELLO` written). Stop removed the lockfile. **Caveat:** when driven from `eval` the ediff window did not auto-open (Buffer B created, no control buffer) — a known "ediff needs a real non-side window" issue also seen in the apply-diff change; needs one more check inside an actual runner session where Claude's terminal is a live window. Also note: Claude's own manual-mode permission gate ("make this edit? Yes/No") is separate from and orthogonal to the ediff review.
