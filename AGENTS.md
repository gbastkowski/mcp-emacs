# MCP Emacs Project Guidelines

## Project Overview

**Read `README.md` first** for the project overview, the map of parts, install,
and the architecture diagram. This file only covers conventions and gotchas that
matter when changing the code.

Everything is Emacs Lisp under `elisp/`. Four groups:

- **MCP server** — `mcp-emacs.el` (the `mcp-emacs-*` helpers) and
  `mcp-emacs-server.el` (HTTP server, registries, dispatch, lifecycle). Details
  in `docs/tools.md`.
- **Agent clients** — `agent-backend.el` (shared EIEIO base + event
  vocabulary), `claude-client.el`, `opencode-client.el`, `mcp-emacs-run*.el`,
  `mcp-emacs-ide.el`, `mcp-emacs-remote.el`. Details in `docs/clients.md`.
- **orgspec** — `orgspec*.el`, an org-native spec workflow that is effectively a
  second project sharing the same host. Details in `docs/orgspec.md`.
- **Misc** — `mcp-emacs-report.el` (tooling-issue filing).

`docs/reference.md` is a full guided tour of the source; it is regenerated
deliberately in a separate pass, so don't hand-edit it alongside code changes.

## Architecture Decisions

- web-server gotcha: the request HTTP verb is the *key* of the headers alist
  (e.g. `(:POST . "/mcp")`), not a `:method` entry.
- JSON gotcha: empty objects must be an empty hash table so `json-encode`
  emits `{}` rather than `null` (an empty alist encodes to `null`).
- `mcp-emacs-server-ensure` is idempotent: safe from a `config.el` startup hook
  and from `emacsclient --eval`. The server runs event-driven in the daemon;
  `emacsclient` only ever *starts* it, never on the request path.
- Error handling: return a plain status string for empty results (e.g.
  "No active selection"), not an error. The dispatcher wraps `tools/call` /
  `resources/read` errors as JSON-RPC -32603, unknown methods as -32601.

## Code Style

- `.editorconfig` covers indentation, line endings, charset, final newline.
- Follow the surrounding Elisp conventions: `lexical-binding: t`, a
  `mcp-emacs-server--` prefix for internal helpers, docstrings on every defun.
- Git commits follow the tbaggery guidelines: short imperative subject
  (~50 chars), body wrapped at ~72 chars explaining *why*, brief unless detail
  is essential.

## Adding a Tool or Resource

- **Tool**: append a plist to the `mcp-emacs-server--tools` registry with
  `:name`, `:description`, `:schema` (JSON input schema, built with the
  `mcp-emacs-server--obj`/`--prop` helpers), and `:handler` (a function of the
  parsed `arguments` alist returning the text result). Put the actual work in a
  `mcp-emacs-*` helper in `mcp-emacs.el` and call it from the handler.
- **Resource**: append to `mcp-emacs-server--resources` with `:uri`, `:name`,
  `:description`, `:mime`, and `:reader`.

## Testing

**Never test in the working Emacs.** Fixtures pop windows, ediffs and
`*claude-client*` buffers into whatever is being edited, and anything that
wedges the instance takes the working session with it. Everything goes through
`bin/test-emacs.sh`, which runs in an Emacs of its own — its own init directory
(`test/init/`, no Doom, no user config), its own `emacsclient` socket
(`mcp-emacs-test`), the MCP server on **8775** instead of 8765, and packages
plus runtime state under the git-ignored `.test-emacs/`.

```sh
bin/test-emacs.sh                     # every suite, batch
bin/test-emacs.sh --quiet             # per-suite report only (what CI runs)
bin/test-emacs.sh test/foo-test.el    # one or more suites
bin/test-emacs.sh --compile           # byte-compile elisp/
bin/test-emacs.sh --compile --strict  # ... warnings fatal
bin/test-emacs.sh --daemon            # leave a test daemon up
bin/test-emacs.sh --eval FORM         # eval in the test daemon
bin/test-emacs.sh --gui               # windowed test instance
bin/test-emacs.sh --stop
```

Every run ends with a per-suite report (`N pass`, `N fail`, verdict) and a
totals line. A suite passes only if it exits clean *and* prints at least one
`PASS`; one that dies before asserting anything is `ERRORED`/`NO ASSERTIONS`,
not a pass. The suites don't use `ert-run-tests-batch` — each has its own
`check` that princ's `PASS name`/`FAIL name`, and the script tallies those, so
a new suite must keep that convention to be counted. CI calls the same script,
so the local loop and CI cannot drift.

For end-to-end pokes at the HTTP surface, start the server inside the test
instance and curl its port:

```sh
bin/test-emacs.sh --eval '(progn (require (quote mcp-emacs-server)) (mcp-emacs-server-ensure))'
curl -s -X POST http://localhost:8775/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Reload after edits with `bin/test-emacs.sh --eval '(load-file "elisp/....el")'`,
or just `--stop` and start fresh.

## Future Enhancements

Potential additions (not yet implemented):
- MCP HTTP niceties: SSE responses (`Accept: text/event-stream`), session-id header, `notifications/initialized`
- File system operations via dired
