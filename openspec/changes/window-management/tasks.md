## 1. Configurable char width with fraction clamp

- [ ] 1.1 Add `mcp-emacs-run-window-width-columns` custom (integer, default 120) to `elisp/mcp-emacs-run.el`
- [ ] 1.2 Add `mcp-emacs-run-window-max-width-fraction` custom (float, default 0.5)
- [ ] 1.3 Add `mcp-emacs-run--resolved-width` helper: prefer columns custom, fall back to existing fraction, clamp to max-fraction of `frame-width`
- [ ] 1.4 Update `mcp-emacs-run--display` to feed the resolved integer width to the `window-width` action for `left`/`right` directions
- [ ] 1.5 Remove the stale `TODO specify size in columns/lines` comment

## 2. Weak dedication

- [ ] 2.1 In `mcp-emacs-run--display`, after obtaining the window, `(set-window-dedicated-p window t)` (weak) before the optional `select-window`
- [ ] 2.2 Update the `mcp-emacs-run-window-direction` docstring so it no longer claims the window is "non-dedicated"

## 3. Verify

- [ ] 3.1 Byte-compile / load `elisp/mcp-emacs-run.el` clean (no warnings)
- [ ] 3.2 Run `sh test/run.sh` (or existing test entrypoint) green
- [ ] 3.3 Manual check in live Emacs: runner opens ~120 cols on a wide frame; clamps on a narrow frame; opening another buffer via find-file lands elsewhere while Claude stays visible; window still splits
