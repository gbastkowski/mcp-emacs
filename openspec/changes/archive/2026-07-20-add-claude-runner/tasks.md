## 1. Scaffolding

- [x] 1.1 Create `elisp/mcp-emacs-run.el` with header, `(require 'eat nil t)` soft dep, `declare-function eat-make`, and an `mcp-emacs`/`mcp-emacs-run` customization group
- [x] 1.2 Add defcustoms: `claude` executable path, extra CLI flags, and whether showing the runner window selects it (focus)
- [x] 1.3 Add an eat-availability guard helper that errors clearly ("install eat") when eat is absent

## 2. Launch

- [x] 2.1 Implement project-root resolution (via `project-current`/`project-root`, falling back to the buffer's `default-directory`)
- [x] 2.2 Implement the launch function: bind `default-directory` to the project root and call `eat-make` with the runner buffer name, configured executable, and switches (design D1)
- [x] 2.3 Honour the configured executable path and extra CLI flags

## 3. Sessions

- [x] 3.1 Implement a per-project registry (project root -> runner buffer) with buffer name `*claude:<project>*` (design D2)
- [x] 3.2 Reuse an existing live session for a project instead of launching a duplicate
- [x] 3.3 Implement list (over live registry entries), switch (`completing-read`), and kill (terminate process, drop registry entry)

## 4. Window management

- [x] 4.1 Implement show via `display-buffer` with a side-window alist entry (design D3)
- [x] 4.2 Implement hide (without killing the process) and toggle
- [x] 4.3 Honour the focus defcustom when showing the window

## 5. Continue / resume

- [x] 5.1 Implement a continue entry command that adds the CLI continue flag to the launch switches (design D4)
- [x] 5.2 Implement a resume entry command that adds the CLI resume flag

## 6. Verification and docs

- [x] 6.1 Byte-compile `elisp/mcp-emacs-run.el` clean (no unconditional eat require; soft-dep guard verified)
- [x] 6.2 Headless checks that need no terminal: project-root resolution returns the expected root; the registry reuses a buffer for the same project; eat-absent path returns the clear error
- [ ] 6.3 Live smoke test in a real Emacs: launch the runner in a project, verify the CLI starts in an eat side window at the project root, toggle the window, and exercise continue/resume (requires eat and the `claude` CLI; done manually)
- [x] 6.4 Update `README.md` with a runner section (commands, eat requirement, that editor tools come from mcp-emacs over MCP)
