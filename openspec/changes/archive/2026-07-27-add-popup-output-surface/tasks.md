## 1. Popup output surface primitive

- [x] 1.1 Add a soft dependency on `markdown-mode` (`require 'markdown-mode nil t`); add an `--ensure-markdown` helper that signals a clear `user-error` with an install hint when absent, mirroring the `eat` pattern.
- [x] 1.2 Add `mcp-emacs-run--popup-buffer-name` deriving a dedicated buffer name from a kind identifier (e.g. `*mcp-emacs:explain*`).
- [x] 1.3 Implement `mcp-emacs-popup-show (content &optional kind)`: get-or-create the per-kind buffer, erase and insert CONTENT read-only, enable `gfm-view-mode`, set `markdown-fontify-code-blocks-natively` buffer-local, then `font-lock-flush`/`font-lock-ensure` so fenced code fontifies; move point to `point-min`.
- [x] 1.4 Display the buffer in a regular split via `display-buffer` (no side window, no auto-hide); reuse the existing window when the buffer is already shown.
- [x] 1.5 Add customization for popup window placement/size if it should differ from the runner window defaults; otherwise document that it uses plain `display-buffer`.

## 2. Headless query text source

- [x] 2.1 Implement `mcp-emacs-run--query-headless (prompt callback)`: run `claude -p PROMPT --output-format text` asynchronously from the project root via `make-process`/`start-process`, accumulate stdout, and invoke CALLBACK with the collected markdown on a successful sentinel.
- [x] 2.2 On process failure or non-zero exit, surface stderr/exit status to the user rather than rendering an empty popup.
- [x] 2.3 Keep the invocation behind this single function so it can later be swapped for the deferred agent backend without touching the render primitive.

## 3. Route explain-selection by session visibility

- [x] 3.1 Add a helper to test whether the current project's session buffer is visible in any window (`get-buffer-window` on the live buffer).
- [x] 3.2 Modify `mcp-emacs-explain-selection-in-current-session`: when the session buffer is visible, keep the current behavior (send `explain <ref>` to the TUI). When it is not visible, build the explain prompt, show a "working…" placeholder popup, run the headless query, and render the result via `mcp-emacs-popup-show` with kind `explain`.
- [x] 3.3 Preserve the no-live-session behavior: report that there is no session and do not launch the CLI.

## 4. Verify

- [x] 4.1 Byte-compile `elisp/mcp-emacs-run.el` cleanly (no new warnings).
- [x] 4.2 Verified via ERT: `popup-*` tests (regular split, read-only, code fontified, per-kind reuse, point at top) all pass.
- [x] 4.3 Verified via ERT: `explain-visible-routes-tui`, `explain-hidden-routes-popup`, `explain-no-session-routes-popup` all pass; `query-*` tests cover the headless path.
- [x] 4.4 Update README with the popup behavior and the `markdown-mode` dependency.

Note: this change's implementation had already landed on `main` in earlier
commits (popup primitive, headless query, explain routing, README) and the
`markdown-mode` dependency is provided by Doom's `:lang markdown`; this
completes the bookkeeping and archives it.
