# mcp-emacs (Claude Code plugin)

Registers the in-Emacs MCP HTTP server with Claude Code and ships skills and a
command for working in a live Emacs session.

## Prerequisite

The Emacs side must be running. Install `mcp-emacs` in Emacs (see the repo
root `README.md`) and make sure the server is listening:

```
emacsclient --eval '(mcp-emacs-server-ensure)'   # returns the endpoint URL
```

Default endpoint: `http://localhost:8765/mcp`. If you changed
`mcp-emacs-server-port`, edit the `url` in `.mcp.json` to match.

## Install

From this repository (local marketplace):

```
/plugin marketplace add /path/to/mcp-emacs
/plugin install mcp-emacs@mcp-emacs
```

Or for one session, point Claude Code at the plugin dir:

```
claude --plugin-dir /path/to/mcp-emacs
```

## What you get

- **MCP server `emacs`** — all `mcp-emacs` tools (buffers, Org, xref,
  diagnostics, `eval`, and the `org_task_*` session tools).
- **`/mcp-emacs:emacs-loop [file.org]`** — start the cooperative Org-task
  session loop.
- **Skills** (auto-invoked by context):
  - `org-task-loop` — cooperative human/AI Org-task session loop.
  - `edit-at-point` — edit the buffer/selection the user is actually looking at.
  - `review-diagnostics` — fix code problems the checker reports.
  - `diagnose-emacs` — troubleshoot the Emacs/tooling setup itself.
