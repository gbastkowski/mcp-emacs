## Why

opencode ships a headless HTTP server (`opencode serve`, default
`127.0.0.1:4096`, OpenAPI 3.1 at `/doc`) with a Server-Sent Events stream for
real-time updates. Unlike the Claude Code CLI — a full-screen TUI reachable only
through a proprietary IDE WebSocket — opencode exposes a clean, documented API.
That makes a **native Emacs client** feasible: drive opencode over HTTP/SSE and
render the conversation in ordinary Emacs buffers, instead of embedding a
terminal. Editor-tool integration is already handled: `opencode.json` wires the
`emacs` MCP server, so opencode reaches Emacs tools through `mcp-emacs` over MCP.

## What Changes

- Add a new file `elisp/opencode-client.el` (a client, distinct from the MCP
  server, kept in this repo alongside the runner work).
- Use **plz.el** for HTTP and SSE (`:as (stream ...)`), loaded as a
  soft/optional dependency (`featurep`-guarded), matching `mcp-emacs`'s
  dependency-light design — no new hard package dependency.
- **Connection**: start or attach to `opencode serve`; health-check via
  `/api/health`; configurable host, port, and optional
  `OPENCODE_SERVER_PASSWORD` basic auth.
- **Sessions**: list (`GET /api/session`), create (`POST /api/session`),
  select/switch the active session, delete.
- **Prompt**: send via `POST /api/session/{id}/prompt` (PromptInput body,
  `delivery` = `steer` | `queue`); interrupt via
  `POST /api/session/{id}/interrupt`.
- **Streaming**: subscribe to the per-session SSE stream
  `GET /api/session/{id}/event` and render incrementally from the `Sync*`
  message-part events (`MessageUpdated`, `MessagePartUpdated/Removed`,
  Text/Reasoning/Tool/Step Started/Ended) into a chat buffer.
- **Interactive prompts**: surface and reply to opencode permission requests
  (`/api/session/{id}/permission`) and questions
  (`/api/session/{id}/question`) from Emacs.
- The `opencode` executable, host, port, and password are customizable.
- Out of scope: reimplementing editor tools (opencode gets those from
  `mcp-emacs` over MCP), and running the opencode TUI in a terminal (this is a
  native API client, not a terminal wrapper).

## Capabilities

### New Capabilities
- `opencode-client`: a native Emacs client for opencode's local HTTP API —
  connection/health, session management, prompting with steer/queue and
  interrupt, incremental SSE rendering into a chat buffer, and handling of
  permission/question interactions.

### Modified Capabilities
<!-- None. Additive, standalone capability in a new file. -->

## Impact

- New file `elisp/opencode-client.el`; no changes to `mcp-emacs.el`,
  `mcp-emacs-server.el`, or the runner file.
- New customizations: opencode executable path, host, port, password.
- Dependencies: `plz` used opportunistically (soft require / `featurep`); no new
  hard package dependency. `json` is built in.
- Relies on the existing `opencode.json` MCP wiring for editor tools; no change
  needed there.
- No breaking changes; purely additive.
