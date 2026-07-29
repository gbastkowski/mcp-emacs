# Protocol spike findings

Source: reverse-engineered from `claude-code-ide.el`, then **verified live**
against Claude Code **v2.1.212** on 2026-07-28 by standing up a throwaway
`websocket.el` server in the user's Emacs, launching `claude` with the IDE env
vars, and driving a real edit through `openDiff` (accept and reject). The
live-verified contract below supersedes the reference where they differ.

## Live verification summary (v2.1.212)

Confirmed end to end:
- Env-var launch triggers the IDE connection (interactive mode only — see below).
- Handshake, `openDiff` args, and the accept/reject return contract all work.
- **Accept** (`FILE_SAVED` + content) → Claude Code applies the edit (file written).
- **Reject** (`DIFF_REJECTED` + tab_name) → file left unchanged, Claude Code stops.

### Protocol drift from the reference (IMPORTANT)
- **protocolVersion is `2025-11-25`**, not `2024-11-05`. Claude sends it in
  `initialize`; our server echoed `2025-11-25` and the session held.
- **`-p` / print (headless) mode does NOT connect to the IDE.** It edits the
  file directly, no `openDiff`. IDE integration only happens in **interactive**
  mode (a real TTY / terminal buffer). The runner must launch interactive Claude.
- Claude sends a **trust prompt** ("Is this a project you trust?") on first run
  in a directory; until it's answered the process never connects. The runner
  must handle/appease this (trust the workspace).
- **Every `tools/call` must be answered or Claude blocks** ("Percolating…").
  Before each native edit Claude calls, in order: `closeAllDiffTabs {}`,
  `getDiagnostics {}`, then `openDiff`. Unanswered `closeAllDiffTabs`/
  `getDiagnostics` stall the whole edit. So the IDE surface MUST implement (at
  least stub) `closeAllDiffTabs` and `getDiagnostics`, not only `openDiff`.

### Observed message sequence (verified)
```
→ initialize  {protocolVersion:"2025-11-25", capabilities:{roots:{listChanged},elicitation:{}}, clientInfo:{name:"claude-code",version:"2.1.212"}}  id 0
← initialize result {protocolVersion:"2025-11-25", capabilities:{tools:{listChanged}}, serverInfo}
→ notifications/initialized            (notification)
→ ide_connected {pid: <claude-pid>}    (notification — NOT in the reference)
→ tools/list  id 1                     ← must return the tool list
--- on a native edit ---
→ tools/call closeAllDiffTabs {}                       id 2   (must answer)
→ tools/call getDiagnostics  {}                        id 3   (must answer)
→ tools/call openDiff {old_file_path,new_file_path,new_file_contents,tab_name}  id 4  (DEFERRED)
← (later) openDiff result: FILE_SAVED+content  OR  DIFF_REJECTED+tab_name
→ tools/call getDiagnostics {uri:"file://…"}           (post-edit; also plain {})
```

### openDiff arguments (verified, v2.1.212)
```json
{
  "old_file_path": "/abs/path/hello.txt",
  "new_file_path": "/abs/path/hello.txt",      // same as old
  "new_file_contents": "FIRST\nline two\n",     // full new file content
  "tab_name": "✻ [Claude Code] hello.txt (61e49d) ⧉"   // Claude-generated, unicode markers + short hash
}
```
Plus `_meta.progressToken` on the call. `tab_name` is opaque — echo it back in
the response (esp. on reject) and use it as the diff-session key.

### openDiff return (verified)
Deferred: do NOT respond when called; respond when the human resolves.
- Accept: `result.content = [{type:"text",text:"FILE_SAVED"}, {type:"text",text:<final content>}]` → Claude writes the file.
- Reject: `result.content = [{type:"text",text:"DIFF_REJECTED"}, {type:"text",text:<tab_name>}]` → file unchanged.

---

## Original reference-derived findings (claude-code-ide.el)

Below is what was extracted from the reference before live verification. Kept
for provenance; where it disagrees with the live section above (protocol
version, ide_connected, mandatory closeAllDiffTabs/getDiagnostics), the live
section wins.

## Discovery is push-by-env, not lockfile-scan (KEY CORRECTION)

The lockfile is **not** the primary discovery mechanism. Claude Code connects
because **Emacs launches the Claude CLI** with environment variables telling it
where the IDE socket is (`claude-code-ide.el:798-801`):

```
CLAUDE_CODE_SSE_PORT=<port>     ; the WebSocket server port
ENABLE_IDE_INTEGRATION=true     ; turns on IDE integration in the CLI
TERM_PROGRAM=emacs
FORCE_CODE_TERMINAL=true
```

The CLI then connects to `ws://127.0.0.1:<port>`.

**Implication for mcp-emacs:** to get native-edit diff review, mcp-emacs must
*launch the Claude Code process itself* (a runner) with `CLAUDE_CODE_SSE_PORT`
and `ENABLE_IDE_INTEGRATION=true` in the environment. A Claude Code started
independently (e.g. the current TUI the user runs by hand) will not connect to
an IDE it wasn't told about via env. This ties issue #10 to the existing
claude-runner work — the runner is where the env vars get injected.

The `~/.claude/ide/<port>.lock` file (schema below) is still written; it appears
to be informational / for other clients that *do* scan. `CLAUDE_CODE_SSE_PORT`
is what actually drives this CLI's connection.

## Lockfile

Path: `~/.claude/ide/<port>.lock` (`claude-code-ide-mcp.el:178-201`).
Content (JSON):

```json
{
  "pid": <emacs-pid>,
  "workspaceFolders": ["<project-root>"],
  "ideName": "Emacs",
  "transport": "ws"
}
```

No auth token in this implementation.

## WebSocket transport

- Emacs runs a **WebSocket server** via `websocket.el` (`websocket-server`),
  bound to `127.0.0.1`, subprotocol `"mcp"` (`claude-code-ide-mcp.el:486-494`).
- Port picked randomly in range 10000–65535.
- Callbacks: `:on-open :on-message :on-error :on-close :on-ping`.
- Claude Code is the WS **client**; it speaks JSON-RPC 2.0 frames as text.

## JSON-RPC methods Claude Code sends (server must handle)

Dispatch in `claude-code-ide-mcp--handle-message` (`:392`):

| method        | response |
|---------------|----------|
| `initialize`  | protocolVersion `2024-11-05`, capabilities (tools.listChanged=t, resources, prompts, logging), serverInfo |
| `tools/list`  | array of `{name, description, inputSchema}` |
| `tools/call`  | `{content: [...]}` — may be **deferred** (no immediate response) |
| `prompts/list`| `{prompts: []}` |
| notifications (no `id`) | ignored |

After `initialize`, server sends a `notifications/tools/list_changed`
notification (~0.1s later).

## Diff tools

### `openDiff` (arguments Claude Code sends) — `handlers.el:463-473`
```
old_file_path     ; original file path
new_file_path     ; usually same as old
new_file_contents ; proposed content
tab_name          ; identifier for this diff
```

### `openDiff` return (the contract that gates the native edit) — `handlers.el:600-644`
`openDiff` is a **deferred** tool: it does NOT respond when called. It opens
ediff, and only when the human resolves does it complete the stored request id.
Two outcomes, sent via `complete-deferred`:

- **Accept** → `content` = two text items: `"FILE_SAVED"` then the final
  (buffer-B) content. Claude Code itself writes the file on `FILE_SAVED`;
  the IDE does *not* save.
- **Reject** → `content` = two text items: `"DIFF_REJECTED"` then the tab name.

(Reference uses a blocking `y-or-n-p` for accept/reject. We will instead reuse
mcp-emacs's cooperative-poll ediff accept/reject flow — no blocking prompt.)

### `close_tab` / `closeAllDiffTabs` — `handlers.el:397-461, 693-712`
Claude Code calls `close_tab {tab_name}` after the edit resolves to tear down
the ediff session; `closeAllDiffTabs` closes all. Handler quits the ediff
control buffer (`ediff-really-quit`) and kills the aux buffers.

## Deferred-response machinery

`tools/call` handlers may return `{deferred t, unique-key ...}`; the server
stores the JSON-RPC `id` per session keyed by tool (and unique-key) and sends
nothing. When the human resolves, `complete-deferred` looks up that id and sends
the response over the same client socket. openDiff relies on this so the socket
isn't blocked while the human reviews — matches mcp-emacs's non-blocking model.

## Consequences for the design

1. **A runner is required.** mcp-emacs must spawn Claude Code with
   `CLAUDE_CODE_SSE_PORT` + `ENABLE_IDE_INTEGRATION=true`. This is the real
   dependency, larger than "add a WS server". Overlaps existing claude-runner
   work — see [[replace-claude-code-ide-goal]] context (runner is the blocker).
2. **Deferred responses over WS**, not synchronous returns — the WS server must
   support responding to a stored request id later, unlike the current
   synchronous HTTP server.
3. Reuse the ediff accept/reject core from `apply_diff`, but the completion path
   sends `FILE_SAVED`+content / `DIFF_REJECTED`+tab over the socket via the
   deferred mechanism.
4. Protocol version to advertise: `2024-11-05`. Subprotocol: `mcp`.

## Still unverified (needs a live Claude Code session)

- Whether a current Claude Code version still uses `CLAUDE_CODE_SSE_PORT` /
  `ENABLE_IDE_INTEGRATION` unchanged, or has moved to a different handshake.
- Exact ordering Claude Code expects (does it call `tools/list` before issuing
  native edits? does it require `openDiff` in that list?).
- Whether `FILE_SAVED` still means "Claude Code writes the file" in the current
  version (affects whether mcp-emacs should save).
- Claude Code version to pin against — record once verified live.
