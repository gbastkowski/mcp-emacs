---
name: edit-at-point
description: Edit the file the user is actually looking at in Emacs, at the cursor or selection, instead of guessing paths. Use when the user says "here", "at point", "this selection", "where my cursor is", "the buffer I have open", or references their current Emacs context without a path.
---

# Edit at point in the live Emacs buffer

The user is working in Emacs. Their cursor position, selection, and current
buffer are real state you can read through the `emacs` MCP tools — use them
instead of asking for a path or guessing.

## Orienting

- `project_info` — project root, active file, tracked file count.
- `get_buffer_filename` — path of the current buffer.
- `get_selection` — the active region, if any.
- `get_current_task_at_point` / `get_current_clocked_task` — Org context.

## Reading context around the cursor

- `get_buffer_content` — full current buffer (includes unsaved edits).
- `imenu_list_symbols` — symbols with line numbers, to locate structure.
- `treesit_info` — tree-sitter node type and ancestor chain at point.

## Editing

- `insert_at_point` — insert text at point, or replace the active selection.
- `edit_file_region` — replace a region by start/end line & column.
  **Emacs coordinates: lines are 1-based, columns are 0-based.** First
  character in the file is line 1, column 0.
- `goto_line` — move point to a line/column, or jump to a named function via
  imenu, before an insert.

## After editing

- Leave saving to the user by default. Only call `save_buffer` if the user
  asks, or if a downstream tool (build, LSP) needs the file on disk — and say
  so when you do.
- Check the result with `get_diagnostics` or `describe_flycheck_info_at_point`
  before declaring the edit clean.
