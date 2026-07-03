# MCP Emacs

Model Context Protocol (MCP) tooling for Emacs.

`mcp-emacs` runs an MCP server **inside your live Emacs session** and speaks MCP
over HTTP. There is no separate process and no `emacsclient` round-trip per
call: tool calls are dispatched directly to the helper functions, so they
observe the real buffers, windows, and Org state of the running session.

## Features

### Tools

| Tool                              | Description                                                                                |
|-----------------------------------|--------------------------------------------------------------------------------------------|
| `get_buffer_content`              | Get the content of the current Emacs buffer                                                |
| `get_buffer_filename`             | Get the filename associated with the current Emacs buffer                                  |
| `get_selection`                   | Get the current selection (region) in Emacs                                                |
| `open_file`                       | Open a file in the current Emacs window                                                    |
| `get_current_clocked_task`        | Get the Org task currently clocked in                                                      |
| `get_current_task_at_point`       | Get the current Org task at point                                                          |
| `edit_file_region`                | Replace text in a file by specifying start/end line & column coordinates (optionally save) |
| `insert_at_point`                 | Insert text at point or replace the current selection in the active buffer                 |
| `goto_line`                       | Jump to a specific line/column or navigate directly to a named function via imenu          |
| `toggle_org_todo`                 | Toggle the TODO keyword (or set a specific state) on the current Org heading               |
| `describe_flycheck_info_at_point` | Get diagnostics at cursor (Flycheck, falling back to Flymake)                              |
| `get_diagnostics`                 | Get all diagnostics for the current buffer (Flycheck or Flymake, auto-detected)            |
| `get_error_context`               | Summarize contents of error-related buffers (*Messages*, *Warnings*, compilation logs)     |
| `save_buffer`                     | Save the current buffer if it is visiting a file                                           |
| `close_buffer`                    | Close the current buffer, optionally saving first                                          |
| `switch_buffer`                   | Switch to a named buffer                                                                    |
| `imenu_list_symbols`              | List the current buffer's symbols (functions, classes, variables) with line numbers        |
| `xref_find_references`            | Find references to an identifier (or the symbol at point) via xref                         |
| `xref_find_apropos`               | Find symbols matching a pattern across the project via xref apropos                        |
| `treesit_info`                    | Tree-sitter node info at point: node type, range, and ancestor chain                       |
| `project_info`                    | Project root, active file, and tracked file count                                          |
| `diagnose_emacs`                  | Collect diagnostic info about the running Emacs (exec-path, LSP clients, …)                 |
| `get_env_vars`                    | List environment variables visible to Emacs                                                |
| `eval`                            | Evaluate an arbitrary Elisp expression in the current buffer context                       |
| `org_task_session`                | Read a session task Org file: task heading, session id, status, and TODO checklist         |
| `org_task_set_session_status`     | Set the session status (Org keyword) of a session task file                                |
| `org_task_set_item_status`        | Set a TODO item's Org keyword, identified by ID/CUSTOM_ID property or heading text          |
| `org_task_append_note`            | Append a progress note to the task body without altering existing content                  |
| `org_task_append_item`            | Append a new TODO item as a child under the task heading                                   |
| `org_task_wait_for_change`        | Block until the task file changes past a baseline token (or a timeout), then return it     |

### Org task session sync

An AI coding harness and the human share one Org file as a live workspace: the
harness reports status into it (via the `org_task_*` tools) while the human
edits the same file in Emacs. The file's first heading is the task — its TODO
keyword is the session status, its `SESSION` property is the session id, and its
child headings are the checklist. All writes go through the live buffer and are
never saved automatically; the AI only updates items it can identify and never
reorders, deletes, or rewrites human-authored items.

For a cooperative loop, `org_task_session` returns a change token and
`org_task_wait_for_change` blocks (up to a timeout, without freezing Emacs)
until the human edits the file, then wakes with the change and the current
session view. The harness works, then waits for the human's next direction —
instead of only seeing edits when it happens to re-read.

### Resources

| Resource            | Description                                                                               |
|---------------------|-------------------------------------------------------------------------------------------|
| `org-tasks://all`   | All TODO items from org-mode agenda files with status, priority, scheduled/deadline dates |
| `buffer://messages` | Live contents of the Emacs `*Messages*` buffer                                            |
| `buffer://warnings` | Live contents of the Emacs `*Warnings*` buffer                                            |

## Prerequisites

- Emacs 28.1+ with the `web-server` package available
- The `mcp-emacs` and `mcp-emacs-server` features loaded in your session

## Installation

Install the package with your preferred Emacs package manager, pointing it at
the `elisp/` directory of this repository.

`straight.el` / `use-package`:

```elisp
(use-package mcp-emacs-server
  :straight (:host github :repo "gbastkowski/mcp-emacs" :files ("elisp/*.el"))
  :init
  (add-hook 'emacs-startup-hook #'mcp-emacs-server-ensure))
```

Or load it manually from a checkout:

```elisp
(add-to-list 'load-path "/path/to/mcp-emacs/elisp")
(require 'mcp-emacs)
(require 'mcp-emacs-server)
(add-hook 'emacs-startup-hook #'mcp-emacs-server-ensure)
```

## Usage with Claude Code

Start the server in Emacs (the `emacs-startup-hook` above does this
automatically), or on demand:

- Interactively: `M-x mcp-emacs-server-start`
- From a shell against a running Emacs server:

  ```bash
  emacsclient --eval '(mcp-emacs-server-ensure)'   # returns the endpoint URL
  ```

Then point the client at the URL:

```json
{
  "emacs": {
    "type": "http",
    "url": "http://localhost:8765/mcp"
  }
}
```

The listening port is configurable via `M-x customize` (`mcp-emacs-server-port`)
or `(setq mcp-emacs-server-port ...)`.

Lifecycle commands: `mcp-emacs-server-start`, `mcp-emacs-server-ensure`
(idempotent), `mcp-emacs-server-stop`, `mcp-emacs-server-running-p`.

## Architecture

- **`elisp/mcp-emacs.el`**: the `mcp-emacs-*` helper functions that do the work
  (buffer, file, Org, diagnostics).
- **`elisp/mcp-emacs-server.el`**: the MCP server. It uses `web-server` to
  listen on an HTTP port, parses each JSON-RPC request, and dispatches directly
  to the helpers via the tool and resource registries.
- **HTTP transport**: the MCP client connects to the URL directly; nothing is
  spawned. Requests are dispatched event-driven in the daemon, so the editor is
  never blocked and tools see real session state.

### Flow Diagram

![Emacs Lisp HTTP server flow](docs/elisp-http.png)

The source PlantUML definition lives in `docs/architecture.puml`. Re-render with
`plantuml -tpng docs/architecture.puml`.
