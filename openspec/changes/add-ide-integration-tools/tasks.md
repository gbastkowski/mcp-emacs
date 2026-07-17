## 1. Editor-state helpers and tools

- [x] 1.1 Add `mcp-emacs-list-open-editors` helper in `elisp/mcp-emacs.el` that returns, for each file-visiting buffer, its file path, buffer name, and modified flag (empty list when none)
- [x] 1.2 Add `mcp-emacs-check-document-dirty` helper that resolves the buffer visiting a given path and returns its dirty state, reporting not-open/not-dirty when no live buffer visits it
- [x] 1.3 Register `list_open_editors` and `check_document_dirty` tool descriptors in `elisp/mcp-emacs-server.el` (`:name`, `:description`, `:schema`, `:handler`)

## 2. Interactive diff/apply helper

- [x] 2.1 Add `defcustom`s for the apply-diff default and max timeout (mirroring `mcp-emacs-org-task-wait-*`), reusing the existing poll interval
- [x] 2.2 Implement `mcp-emacs-apply-diff` in `elisp/mcp-emacs.el`: create Buffer A from the file's current content and Buffer B from the proposed content, save the window configuration, capture Buffer A's entry content, and launch `ediff-buffers`
- [x] 2.3 Install a buffer-local `ediff-quit-hook` on the control buffer that records the outcome into a per-call result cell captured in the closure (per design D2)
- [x] 2.4 On quit, determine outcome by comparing Buffer A's final content to its entry content: changed → `applied` (return final content, leave saving to the human); unchanged → `rejected` (per design D3)
- [x] 2.5 Spin the cooperative wait loop with `accept-process-output` and a bounded deadline until the result cell is set or the timeout elapses (per design D1)
- [x] 2.6 On timeout, force-quit any live ediff control buffer (`ediff-really-quit` guarded, else kill it), restore the saved window configuration, leave Buffer A unmodified, and return `timeout` (per design D4)
- [x] 2.7 Register the `apply_diff` tool descriptor in `elisp/mcp-emacs-server.el` (schema: required `path` + `new_content`, optional `timeout`)

## 3. Cleanup and robustness

- [x] 3.1 Ensure temporary Buffer B and any diff buffers are cleaned up on all exit paths (applied, rejected, timeout, error)
- [x] 3.2 Handle the missing-file / non-Org-agnostic cases gracefully (Buffer A for a nonexistent path, unreadable path) with clear error text rather than a raw signal

## 4. Verification and docs

- [x] 4.1 Byte-compile both elisp files clean (only the known optional-feature warnings), confirming the new hooks/closures parse
- [ ] 4.2 Manually exercise each tool against the live server: `apply_diff` accept, reject, human-edit, and timeout paths; `list_open_editors`; `check_document_dirty`
- [x] 4.3 Update `README.md` tool list and mention `apply_diff` in the relevant skills (`edit-at-point`, `review-diagnostics`)
