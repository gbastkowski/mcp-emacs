## Context

The Claude runner lives in `elisp/mcp-emacs-run.el`. Today
`mcp-emacs-run--display` (around line 145) calls `display-buffer` with a
`display-buffer-in-direction` action and a size cons cell:

```elisp
(size (if horizontal
          `(window-width . ,mcp-emacs-run-window-width)   ; 0.4 → fraction
        `(window-height . ,mcp-emacs-run-window-height)))
```

`window-width` in a `display-buffer` action already accepts either a
fraction (0 < n < 1, interpreted vs frame) or an integer column count —
Emacs' `window--display-buffer` / `window-resize` honour both. There is a
standing `TODO: specify size in columns/lines` at line 80.

The window is an ordinary (splittable) window — the "not a side window"
requirement is already met. Nothing currently dedicates the window.

## Goals / Non-Goals

**Goals:**
- Width configurable in columns, default 120.
- Resolved width clamped to a max fraction of the frame width.
- Runner window weakly dedicated to its Claude buffer.
- Keep the window ordinary/splittable (no regression).

**Non-Goals:**
- opencode, multiple/stacked windows, saveable presets.
- The popup output window (`mcp-emacs-popup-show`) — untouched.
- Vertical (`above`/`below`) direction gets no char-height equivalent in
  this change; height stays fractional.

## Decisions

### Width in columns with a fraction clamp

Add two customs:
- `mcp-emacs-run-window-width-columns` (integer, default 120) — the
  desired width in columns when direction is `left`/`right`.
- `mcp-emacs-run-window-max-width-fraction` (float, default e.g. 0.5) —
  the hard cap as a fraction of frame width.

Keep the existing `mcp-emacs-run-window-width` fraction as the fallback
for backwards compatibility, but prefer the column custom when non-nil.

Resolve the effective width in a small helper:

```elisp
(defun mcp-emacs-run--resolved-width ()
  (let* ((cap (truncate (* mcp-emacs-run-window-max-width-fraction
                           (frame-width))))
         (cols (or mcp-emacs-run-window-width-columns
                   (truncate (* mcp-emacs-run-window-width (frame-width))))))
    (min cols cap)))
```

Feed the integer result to the `window-width` action so `display-buffer`
sizes the window in columns.

### Weak dedication

After `display-buffer` returns the window, mark it weakly dedicated:

```elisp
(set-window-dedicated-p window t)   ; t = weak; 'strong not wanted
```

Weak dedication (value `t`, not a non-nil non-`t` "strong" value) means
`display-buffer` still MAY reuse the window when it is the only candidate,
matching the spec. Do this inside `mcp-emacs-run--display` right where the
window is obtained, before the optional `select-window`.

## Risks / Trade-offs

- **Clamp on tiny frames**: on a very narrow frame 120 cols may exceed the
  whole frame; the max-fraction clamp handles this, but the code pane can
  still be small. Acceptable — user controls the fraction.
- **Weak vs strong dedication**: weak was chosen deliberately (per user)
  so the pane is sticky but not a hard lock; a determined `display-buffer`
  with no other window can still reuse it. If clobbering still annoys, a
  later change could offer strong as an option.
- **Height unchanged**: `above`/`below` directions keep fractional height;
  out of scope, noted so it is not mistaken for an oversight.

## Open Questions

- Default for `mcp-emacs-run-window-max-width-fraction`: 0.5 proposed.
  Confirm during implementation if a different cap reads better.
