## Context

`mcp-emacs` is a dependency-light MCP server (Package-Requires: emacs +
web-server). Existing project code (`mcp-emacs-project-info`) uses built-in
`project.el` with a `(require 'project nil t)` guard and no hard projectile
dependency; the new tools follow the same discipline.

Two implementation facts drive the diagnostics design:

- **eglot routes LSP diagnostics through Flymake.** In an eglot-managed buffer,
  `flymake-diagnostics` already returns the LSP diagnostics. So "include LSP
  workspace diagnostics when a session is active" does **not** require a separate
  eglot/lsp API — iterating a project's live buffers and reading each buffer's
  Flycheck *or* Flymake diagnostics already captures LSP-backed diagnostics for
  every open, managed buffer.
- **Diagnostics require a live buffer.** Both Flycheck and Flymake (and thus
  eglot) attach diagnostics to buffers. A project file that is not open in any
  buffer has no diagnostics to read, regardless of LSP. This is the documented
  limitation.

## Goals / Non-Goals

**Goals:**
- Rename `get_diagnostics` → `get_buffer_diagnostics` with identical behavior.
- Add `get_project_diagnostics` that aggregates per-buffer diagnostics across all
  live project buffers, attributing each to its file.
- Add `get_workspace_folders`, `list_project_files`, `switch_project`,
  `find_file_in_project` on a `project.el` base with optional projectile.
- Keep zero new hard dependencies.

**Non-Goals:**
- Diagnostics for unopened files (would require batch-linting or a persistent
  LSP index the server does not own).
- A bespoke eglot/lsp-mode diagnostics API path (unnecessary — Flymake is the
  common sink).
- Multi-frame / remote (TRAMP) project nuances beyond what project.el handles.

## Decisions

### D1: Rename is a pure identifier change
`mcp-emacs-get-diagnostics` becomes `mcp-emacs-get-buffer-diagnostics` and the
tool descriptor `get_diagnostics` becomes `get_buffer_diagnostics`. No behavior
change. All in-repo references (skills, README) are updated in the same change.
No alias is kept — the user accepted a breaking rename with a minor version bump.

### D2: `get_project_diagnostics` reuses the single-buffer logic across project buffers
Factor the current per-buffer Flycheck/Flymake extraction into a helper that
takes a buffer and returns its diagnostics lines. `get_buffer_diagnostics` calls
it for the current buffer; `get_project_diagnostics` resolves the current
project (`project.el`), enumerates the live buffers whose file is under the
project root, and calls the helper for each, prefixing each buffer's output with
its file path. Because eglot feeds Flymake, LSP diagnostics are included for any
managed open buffer with no extra code.

- **Alternative considered:** query `eglot--diagnostics` / lsp-mode workspace
  APIs directly. Rejected — private/unstable APIs, and Flymake already exposes
  the same data uniformly across checkers.

### D3: Project tools use project.el, prefer projectile when loaded
Each project tool branches on `(featurep 'projectile)`:
- `get_workspace_folders`: projectile → `projectile-known-projects`; else
  `project-known-project-roots`.
- `list_project_files`: projectile → `projectile-project-files` /
  `projectile-current-project-files`; else `project-files` of `project-current`.
- `switch_project`: projectile → `projectile-switch-project-by-name`; else
  set the current project via `project-switch-project` / by visiting the root.
- `find_file_in_project`: match a name against the project file list (D3 list
  source) and `find-file` the resolved path.
All projectile symbols are referenced behind the `featurep` guard and declared
with `declare-function`, so byte-compilation stays clean without projectile.

### D4: Error handling mirrors existing tools
Every tool wraps its body in `condition-case` and returns a readable status
string ("Not inside a project", "No match", etc.) instead of signalling, exactly
as `project_info`, `get_error_context`, and the org-task tools do.

## Risks / Trade-offs

- **Project diagnostics miss unopened files** → documented in the tool
  description and the spec; acceptable given the buffer-attached nature of
  diagnostics. A future enhancement could open files on demand, but that is out
  of scope.
- **projectile vs project.el semantic drift** (e.g. different file lists / root
  detection) → both branches return the same *kind* of information; the spec
  only requires equivalent categories, not byte-identical lists.
- **`switch_project` changes global editor state** → it is an explicit,
  user-invoked action; the tool confirms the switch and leaves state unchanged on
  an invalid target (D4).

## Open Questions

- Should `switch_project` accept a project *name* (projectile-style) or a *root
  path* (project.el-style)? Plan: accept a root path as the canonical input and,
  when projectile is present, also resolve a known project name; document both.
