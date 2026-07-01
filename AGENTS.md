# MCP Emacs Project Guidelines

## Project Overview

**Read `README.md` first** for the project overview, the two server
implementations (Emacs Lisp HTTP + Node.js stdio), repository layout, tech
stack, and architecture diagrams. This file only covers conventions and
gotchas that matter when changing the code.

## Architecture Decisions

### Emacs Lisp server (HTTP)
- web-server gotcha: the request HTTP verb is the *key* of the headers alist
  (e.g. `(:POST . "/mcp")`), not a `:method` entry.
- JSON gotcha: empty objects must be an empty hash table so `json-encode`
  emits `{}` rather than `null` (an empty alist encodes to `null`).
- `mcp-emacs-server-ensure` is idempotent: safe from `config.el` startup hook
  and from the launcher script. `emacsclient` starts the server, never on the
  request path.

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

Formatting and linting are enforced by tooling, not this file:

- `.editorconfig` — indentation, line endings, charset, final newline, line length.
- Prettier (`.prettierrc.json`) — run `npm run format` (or `format:check`).
- ESLint (`eslint.config.mjs`, typescript-eslint) — run `npm run lint`. Includes
  member-ordering (public members before private) and honours `_`-prefixed
  unused args.

Conventions not covered by tooling:

- Prefer explicit types over inference where it improves clarity.
- For simple `switch` branches prefer single-line `case` statements
  (`case "x": doWork(); break`).
- Git commits follow the tbaggery guidelines: short imperative subject
  (~50 chars), body wrapped at ~72 chars explaining *why*, brief unless detail
  is essential.

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
- File system operations via dired
