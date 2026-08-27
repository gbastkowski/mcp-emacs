# The MCP server: tools and resources

`mcp-emacs` runs an MCP server **inside your live Emacs session** and speaks MCP
over HTTP. There is no separate process and no `emacsclient` round-trip per
call: tool calls are dispatched directly to the helper functions, so they
observe the real buffers, windows, and Org state of the running session.

See the [README](../README.md) for install and quickstart.

## Buffers, files, and editing

| Tool                  | Description                                                                                |
|-----------------------|--------------------------------------------------------------------------------------------|
| `get_buffer_content`  | Get the content of the current Emacs buffer                                                |
| `get_buffer_filename` | Get the filename associated with the current Emacs buffer                                  |
| `get_selection`       | Get the current selection (region) in Emacs                                                |
| `open_file`           | Open a file in the current Emacs window                                                    |
| `edit_file_region`    | Replace text in a file by specifying start/end line & column coordinates (optionally save) |
| `insert_at_point`     | Insert text at point or replace the current selection in the active buffer                 |
| `goto_line`           | Jump to a specific line/column or navigate directly to a named function via imenu          |
| `apply_diff`          | Propose new file content via an interactive ediff session; returns applied/rejected/timeout |
| `save_buffer`         | Save the current buffer if it is visiting a file                                           |
| `close_buffer`        | Close the current buffer, optionally saving first                                          |
| `switch_buffer`       | Switch to a named buffer                                                                    |
| `list_open_editors`   | List file-visiting buffers with their path, buffer name, and dirty flag                    |
| `check_document_dirty`| Report whether the buffer visiting a file has unsaved changes                              |

## Code intelligence

| Tool                              | Description                                                                                |
|-----------------------------------|--------------------------------------------------------------------------------------------|
| `imenu_list_symbols`              | List the current buffer's symbols (functions, classes, variables) with line numbers        |
| `xref_find_references`            | Find references to an identifier (or the symbol at point) via xref                         |
| `xref_find_apropos`               | Find symbols matching a pattern across the project via xref apropos                        |
| `treesit_info`                    | Tree-sitter node info at point: node type, range, and ancestor chain                       |
| `describe_flycheck_info_at_point` | Get diagnostics at cursor (Flycheck, falling back to Flymake)                              |
| `get_buffer_diagnostics`          | Get code diagnostics for the current buffer (Flycheck or Flymake, auto-detected)           |
| `get_project_diagnostics`         | Aggregate code diagnostics across open project buffers (LSP via Flymake); unopened files not covered |
| `get_error_context`               | Summarize contents of error-related buffers (*Messages*, *Warnings*, compilation logs)     |

## Project

| Tool                    | Description                                                                |
|-------------------------|----------------------------------------------------------------------------|
| `project_info`          | Project root, active file, and tracked file count                          |
| `get_workspace_folders` | List the project/workspace roots Emacs knows about                         |
| `list_project_files`    | List the files tracked in the current project                              |
| `switch_project`        | Switch Emacs's active project so later tools operate in that context       |
| `find_file_in_project`  | Resolve a file by name within the current project and open it              |

## Org

| Tool                        | Description                                                       |
|-----------------------------|-------------------------------------------------------------------|
| `get_current_clocked_task`  | Get the Org task currently clocked in                             |
| `get_current_task_at_point` | Get the current Org task at point                                 |
| `toggle_org_todo`           | Toggle the TODO keyword (or set a specific state) on the current Org heading |

## Environment and escape hatch

| Tool             | Description                                                        |
|------------------|--------------------------------------------------------------------|
| `diagnose_emacs` | Collect diagnostic info about the running Emacs (exec-path, LSP clients, …) |
| `get_env_vars`   | List environment variables visible to Emacs                        |
| `eval`           | Evaluate an arbitrary Elisp expression in the current buffer context |

## Cooperative Org task sessions

An AI coding harness and the human share one Org file as a live workspace: the
harness reports status into it while the human edits the same file in Emacs. The
file's first heading is the task — its TODO keyword is the session status, its
`SESSION` property is the session id, and its child headings are the checklist.
All writes go through the live buffer and are never saved automatically; the AI
only updates items it can identify and never reorders, deletes, or rewrites
human-authored items.

For a cooperative loop, `org_task_session` returns a change token and
`org_task_wait_for_change` blocks (up to a timeout, without freezing Emacs)
until the human edits the file, then wakes with the change and the current
session view. The harness works, then waits for the human's next direction —
instead of only seeing edits when it happens to re-read.

| Tool                          | Description                                                                        |
|-------------------------------|------------------------------------------------------------------------------------|
| `org_task_session`            | Read a session task Org file: task heading, session id, status, and TODO checklist |
| `org_task_set_session_status` | Set the session status (Org keyword) of a session task file                        |
| `org_task_set_item_status`    | Set a TODO item's Org keyword, identified by ID/CUSTOM_ID property or heading text |
| `org_task_append_note`        | Append a progress note to the task body without altering existing content          |
| `org_task_append_item`        | Append a new TODO item as a child under the task heading                           |
| `org_task_wait_for_change`    | Block until the task file changes past a baseline token (or a timeout), then return it |

The `org-task-loop` skill and the `/mcp-emacs:emacs-loop` command drive this
protocol for you.

## orgspec tools

The typed `orgspec_*` tools are documented in [orgspec.md](orgspec.md).

## Report a tooling issue

When a tool or skill from mcp-emacs misbehaves — or you want a feature — the
`report_tooling_issue` tool files it as a GitHub issue on
`gbastkowski/mcp-emacs`, so you can report from inside the assistant instead of
switching to GitHub by hand. It takes a `title`, an optional `description`, and
an optional `kind` (`bug` / `feature` / `skill` / `server`) applied as a label.

Filing is resilient: it uses the `gh` CLI, falling back to `gh api`; when no
GitHub mechanism is available it hands back the composed issue text for manual
filing. The `report-issue` skill wraps this in a guided flow — classify, draft,
confirm, file, report the URL — and prefers the `github` MCP server when one is
connected. The target repo is fixed: this reports issues about mcp-emacs
itself, not arbitrary repositories.

## Resources

| Resource            | Description                                                                               |
|---------------------|-------------------------------------------------------------------------------------------|
| `org-tasks://all`   | All TODO items from org-mode agenda files with status, priority, scheduled/deadline dates |
| `buffer://messages` | Live contents of the Emacs `*Messages*` buffer                                            |
| `buffer://warnings` | Live contents of the Emacs `*Warnings*` buffer                                            |

## Adding a tool

See [AGENTS.md](../AGENTS.md) for the registry conventions, and
[reference.md](reference.md) for a full tour of the code.
