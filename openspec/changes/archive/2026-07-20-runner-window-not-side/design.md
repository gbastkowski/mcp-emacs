## Context

`mcp-emacs-run--display` calls `display-buffer` with `display-buffer-in-side-window`, a `side` slot from `mcp-emacs-run-window-side`, and a `window-width` from `mcp-emacs-run-window-width`. Side windows are dedicated and edge-anchored: not splittable, skipped by `other-window`, immune to `delete-other-windows`. That is the flexibility cost the user hit.

## Goals / Non-Goals

**Goals:**
- Place the runner in an ordinary window in a predictable direction, splittable/navigable/closable like any other.
- Keep a size hint and keep the focus-on-show behavior.

**Non-Goals:**
- No fully user-supplied `display-buffer-alist` strategy (single directional action is enough here).
- No change to session management, reveal, or headless behavior — only where/how the window is placed.

## Decisions

- **Use `display-buffer-in-direction`.** `mcp-emacs-run--display` builds an action `((display-buffer-in-direction) (direction . <dir>) (window-width . <w>) (window-height . <h>))`. The resulting window is not dedicated, so `split-window`, `other-window`, and `delete-other-windows` treat it normally.
- **Replace the side defcustom.** `mcp-emacs-run-window-side` → `mcp-emacs-run-window-direction` (choice `right`/`left`/`above`/`below`, default `right`). Keep `mcp-emacs-run-window-width` as the size hint for left/right; add `mcp-emacs-run-window-height` for above/below. Only the hint matching the direction's axis is passed.
- **Reveal/toggle unchanged.** They rely on `get-buffer-window` / `delete-window`, which work on ordinary windows too.

## Risks / Trade-offs

- `display-buffer-in-direction` is Emacs 27+. mcp-emacs already targets modern Emacs (eat, project.el), so acceptable.
- Removing `mcp-emacs-run-window-side` is a config breaking change; called out in the proposal. Low blast radius (new feature, personal use).
- An ordinary window can be reused/resized by other `display-buffer` calls; acceptable — that flexibility is the point.
