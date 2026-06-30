# MCP Emacs Project Guidelines

## Project Overview

MCP tooling that enables AI agents to interact with Emacs.
Two server implementations share the same `mcp-emacs-*` helper functions:

- **Emacs Lisp server (recommended)**: runs inside the live Emacs session and
  speaks MCP over HTTP via `web-server`. No Node.js, no per-request
  `emacsclient` round-trip; helpers see the real running session state.
- **Node.js server (fallback)**: standalone Node MCP server bridging to Emacs
  via `emacsclient --eval` over the stdio transport.

Repository layout:
- `.` (repo root): Node.js MCP server module with embedded Emacs Lisp helpers
- `elisp/mcp-emacs.el`: shared tool helper functions (`mcp-emacs-*`)
- `elisp/mcp-emacs-server.el`: in-Emacs HTTP MCP server (registry, dispatch, lifecycle)
- `bin/mcp-emacs-http`: launcher that starts the HTTP server via `emacsclient --eval`

## Tech Stack

- Emacs Lisp with `web-server` (HTTP MCP server)
- TypeScript with @modelcontextprotocol/sdk (Node fallback)
- Node.js (ES modules)
- emacsclient for the Node bridge and for launching the HTTP server
- HTTP transport (Elisp server) / STDIO transport (Node server)

## Architecture Decisions

### Emacs Lisp server (HTTP)
- Runs inside the live daemon; dispatches JSON-RPC directly to `mcp-emacs-*`
  helpers, so tools observe real buffers/windows/Org state.
- Event-driven via `web-server`, so the editor is never blocked.
- `emacsclient` is used only to *start* the server (`mcp-emacs-server-ensure`),
  never on the request path.
- `mcp-emacs-server-ensure` is idempotent: safe from `config.el` startup hook
  and from the launcher script.
- web-server gotcha: the request HTTP verb is the *key* of the headers alist
  (e.g. `(:POST . "/mcp")`), not a `:method` entry.
- JSON gotcha: empty objects must be an empty hash table so `json-encode`
  emits `{}` rather than `null` (an empty alist encodes to `null`).

### Node Emacs communication (fallback)
- Use `emacsclient --eval` for all Emacs interactions
- Timeout set to 5 seconds for safety
- Requires Emacs server mode to be running

### Error Handling
- Catch and wrap emacsclient errors with descriptive messages
- Return "No active selection" for empty regions (not an error)
- HTTP server wraps `tools/call` errors as JSON-RPC error -32603, unknown
  methods as -32601

## Code Style

- Use ES modules (type: "module" in package.json)
- Strict TypeScript configuration
- Prefer explicit types over inference where it improves clarity
- Two-space indentation, LF endings, and final newlines are enforced via `.editorconfig`
- Keep public members at the top of classes, with private helpers grouped below
- Keep short parameter lists on a single line when they fit and avoid trailing commas on the last element/argument
- For simple `switch` branches prefer single-line `case` statements (`case "x": doWork(); break`)
- Git commits should follow the tbaggery guidelines:
  - short imperative subject (~50 chars),
  - wrap additional context at ~72 chars,
  - and keep messages brief unless extra detail is essential.

## Tools & Resources Implementation

Each tool should:
1. Define clear input schema with required fields
2. Use `evalInEmacs()` helper for Elisp evaluation
3. Strip surrounding quotes from Elisp string results
4. Return MCP-compliant response objects with content array

Resources follow the same pattern using the `src/resources` base class. Prefer dedicated resource classes over ad-hoc registrations so metadata, URIs, and read callbacks live together.

For the Elisp HTTP server, each tool is a plist entry in the
`mcp-emacs-server--tools` registry: `:name`, `:description`, `:schema` (JSON
input schema), and `:handler` (a function of the parsed `arguments` alist that
returns the text result). Add a tool by appending a registry entry that calls
the relevant `mcp-emacs-*` helper.

## Testing

### Emacs Lisp server
1. Ensure the Emacs server is running, then start the MCP server:
   `bin/mcp-emacs-http` (prints the endpoint URL).
2. Exercise it with `curl`, e.g.
   `curl -s -X POST http://localhost:8765/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'`.
3. Reload after edits via `emacsclient --eval` `load-file` +
   `mcp-emacs-server-stop`/`-start`.

### Node.js server
1. Start Emacs with server-start
2. Build the MCP server (run `npm run build` from the repo root)
3. Test with MCP client
4. Check emacsclient behavior directly when debugging

## Future Enhancements

Potential additions (not yet implemented):
- MCP HTTP niceties: SSE responses (`Accept: text/event-stream`), session-id header, `notifications/initialized`
- Emacs Lisp evaluation with variable capture
- File system operations via dired
