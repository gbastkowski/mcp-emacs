## 1. Popup output window primitive

- [x] 1.1 Add a soft dependency on `markdown-mode` (`require 'markdown-mode nil t`); add an `--ensure-markdown` helper that signals a clear `user-error` with an install hint when absent, mirroring the `eat` pattern.
- [x] 1.2 Add `mcp-emacs-run--popup-buffer-name` deriving a dedicated buffer name from a kind identifier (e.g. `*mcp-emacs:explain*`).
- [x] 1.3 Implement `mcp-emacs-popup-show (content &optional kind)`: get-or-create the per-kind buffer, erase and insert CONTENT read-only, enable `gfm-view-mode`, set `markdown-fontify-code-blocks-natively` buffer-local, then `font-lock-flush`/`font-lock-ensure` so fenced code fontifies; move point to `point-min`.
- [x] 1.4 Display the buffer in a regular split window that does not auto-hide, reusing the existing window when already shown. Implemented via `mcp-emacs-run--display-popup`, which prepends a buffer-name entry to a local copy of `display-buffer-alist` so `display-buffer-in-direction` wins over framework rules (Doom's `+popup` otherwise forces a transient auto-hiding side window).
- [x] 1.5 Add `mcp-emacs-run-popup-direction` and `mcp-emacs-run-popup-size` customization for popup placement, independent of the runner window defaults.

## 2. Headless query text source

- [x] 2.1 Implement `mcp-emacs-run--query-headless (prompt callback)`: run `claude -p PROMPT --output-format text` asynchronously from the project root via `make-process`, accumulate stdout, and invoke CALLBACK with the collected markdown on a successful sentinel.
- [x] 2.2 On process failure or non-zero exit, report exit status and stderr to the user rather than rendering an empty popup (CALLBACK is not called).
- [x] 2.3 Keep the invocation behind this single function so it can later be swapped for the deferred agent backend without touching the render primitive.

## 3. Route explain-selection by session visibility

- [x] 3.1 Add `mcp-emacs-run--session-visible-p`: tests whether the project's live session buffer is shown in any window (`get-buffer-window ... t`).
- [x] 3.2 Modify `mcp-emacs-explain-selection-in-current-session`: when the session buffer is visible, keep the current behavior (send `explain <ref>` to the TUI). When it is not visible, build the explain prompt, show a "Working…" placeholder popup, run the headless query, and render the result via `mcp-emacs-popup-show` with kind `explain`.
- [x] 3.3 Preserve the no-live-session behavior: report that there is no session and do not launch the CLI.

## 4. Verify

- [x] 4.1 Byte-compile `elisp/mcp-emacs-run.el` cleanly (no new warnings).
- [x] 4.2 Batch tests for the popup primitive in `test/mcp-emacs-run-test.el` (run via `emacs -Q --batch -l test/mcp-emacs-run-test.el`): buffer name, markdown guard, render content, read-only, buffer-local fontify flag, point at top, reuse-per-kind, distinct kinds. (Live-UI checks intentionally skipped; scroll/select/copy follow from it being an ordinary read-only buffer.)
- [x] 4.3 Batch tests for the headless query (exact command line, project-root cwd, success callback, non-zero-exit no-callback) and for explain routing (visible → TUI, hidden → popup + headless, no session → user-error with no sink fired).
- [x] 4.4 Update README with the popup behavior and the `markdown-mode` dependency.
