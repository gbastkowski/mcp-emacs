## 1. Diagnostics rename and refactor

- [x] 1.1 Factor the per-buffer Flycheck/Flymake extraction out of `mcp-emacs-get-diagnostics` into a helper that takes a buffer and returns its diagnostics lines
- [x] 1.2 Rename `mcp-emacs-get-diagnostics` to `mcp-emacs-get-buffer-diagnostics` (delegating to the helper for the current buffer) and rename the `get_diagnostics` tool descriptor to `get_buffer_diagnostics`
- [x] 1.3 Implement `mcp-emacs-get-project-diagnostics`: resolve the current project via `project.el`, iterate live buffers whose file is under the project root, run the helper per buffer, and prefix each buffer's output with its file path; return a readable status when not in a project or when there are none

## 2. Project/workspace tools

- [x] 2.1 Implement `mcp-emacs-get-workspace-folders` (projectile `projectile-known-projects` when loaded, else `project-known-project-roots`), guarded by `featurep` and `declare-function`
- [x] 2.2 Implement `mcp-emacs-list-project-files` (projectile project files when loaded, else `project-files` of `project-current`)
- [x] 2.3 Implement `mcp-emacs-switch-project` accepting a project root path (and a known project name when projectile is present), switching the active project and confirming; leave state unchanged and return a status on an invalid target
- [x] 2.4 Implement `mcp-emacs-find-file-in-project` that resolves a name against the project file list and opens the match, returning the resolved path or a status when there is no match
- [x] 2.5 Wrap each new tool body in `condition-case` returning readable status strings, matching the existing tools

## 3. Tool registration

- [x] 3.1 Register `get_project_diagnostics`, `get_workspace_folders`, `list_project_files`, `switch_project` (schema: `path`), and `find_file_in_project` (schema: `name`) descriptors in `elisp/mcp-emacs-server.el`
- [x] 3.2 Confirm the renamed `get_buffer_diagnostics` descriptor is the only diagnostics-code descriptor and that `get_error_context` / `diagnose_emacs` are untouched

## 4. Verification and docs

- [x] 4.1 Byte-compile both elisp files clean (only known optional-feature warnings); confirm no projectile symbols are required unconditionally
- [x] 4.2 Headless smoke test: `get_buffer_diagnostics` and `get_project_diagnostics` over an open project buffer, `get_workspace_folders`, `list_project_files`, `find_file_in_project`, and `switch_project` on a valid and an invalid target
- [x] 4.3 Update `README.md` tool table (rename + five new tools) and the `review-diagnostics` skill (renamed tool, project-diagnostics option)
