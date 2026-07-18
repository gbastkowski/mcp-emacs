## Why

`mcp-emacs` exposes editor tools to any MCP client, but its diagnostics and
project surface has two gaps. First, `get_diagnostics` is misleadingly named: it
reports **code** diagnostics (Flycheck/Flymake) for the current buffer only,
while Emacs-error investigation lives in `get_error_context` and Emacs health in
`diagnose_emacs` — the name suggests something broader than what it does, and
there is no project-wide view. Second, the only project tool is the read-only
`project_info`; a client cannot enumerate workspace roots, list or find project
files, or switch the active project. Closing these gaps moves `mcp-emacs` toward
full feature parity with `claude-code-ide`'s pull-model editor tools.

## What Changes

- **BREAKING**: Rename the `get_diagnostics` tool to `get_buffer_diagnostics`.
  Behavior is unchanged (current-buffer Flycheck/Flymake code diagnostics); only
  the tool name changes, to make the buffer scope explicit. Update the skills
  and README that reference it.
- Add `get_project_diagnostics`: aggregate code diagnostics across the project —
  from all live project buffers (Flycheck/Flymake) and, when an eglot/lsp-mode
  session is active, the LSP workspace diagnostics. Unopened files with no LSP
  session are not covered; this limitation is documented in the tool.
- Add `get_workspace_folders`: list the project/workspace roots Emacs knows.
- Add `list_project_files`: list the files tracked in the current project.
- Add `switch_project`: change Emacs's active project so subsequent tools operate
  in that project's context.
- Add `find_file_in_project`: resolve (and open) a file by name within the
  current project.
- All four project tools use built-in `project.el` as the base and use
  `projectile` opportunistically when it is loaded (`featurep` check), adding no
  new hard package dependency — mirroring the existing `project_info` tool.
- Unchanged: `get_error_context` (Emacs errors) and `diagnose_emacs` (Emacs
  health) keep their names and behavior.

## Capabilities

### New Capabilities
- `diagnostics-tools`: code-diagnostics MCP tools — buffer-scoped
  (`get_buffer_diagnostics`) and project-scoped (`get_project_diagnostics`),
  distinct from Emacs-error and Emacs-health tooling.
- `project-workspace-tools`: project/workspace management MCP tools —
  enumerate workspace roots, list project files, switch the active project, and
  find a file within the project, backed by `project.el` with optional
  `projectile`.

### Modified Capabilities
<!-- None. get_diagnostics predates OpenSpec and has no existing spec; its rename is captured under the new diagnostics-tools capability. project_info predates OpenSpec and is unchanged. -->

## Impact

- `elisp/mcp-emacs.el`: rename `mcp-emacs-get-diagnostics` →
  `mcp-emacs-get-buffer-diagnostics`; add `mcp-emacs-get-project-diagnostics`
  and four project/workspace helper functions (project.el base, projectile
  fallback).
- `elisp/mcp-emacs-server.el`: rename the `get_diagnostics` descriptor to
  `get_buffer_diagnostics`; register `get_project_diagnostics`,
  `get_workspace_folders`, `list_project_files`, `switch_project`, and
  `find_file_in_project`.
- Docs: update `README.md` tool table and the `review-diagnostics` /
  `edit-at-point` skills for the renamed tool and the new tools.
- **Breaking for clients**: any client or config referencing `get_diagnostics`
  must switch to `get_buffer_diagnostics`. Warrants a minor version bump.
- No new package dependencies.
