## Why

The Claude Code runner window (`mcp-emacs-run.el`) already opens in a
normal splittable window via `display-buffer-in-direction`, but its width
is expressed only as a fraction of the frame (`mcp-emacs-run-window-width`,
default 0.4), and the window is not dedicated — so during normal editing
Emacs may reuse it for other buffers and clobber the agent pane. There is
already a `TODO: specify size in columns/lines` in the code.
We want the runner to open at a configurable **character** width (default
120), clamped to a max frame fraction, and to stay showing Claude.

## What Changes

- Allow the runner window width to be specified in **columns** (default
  120) in addition to / instead of the current frame fraction.
- **Clamp** the resolved char width to a configurable maximum fraction of
  the frame so the code pane is not crushed on narrow frames.
- Make the runner window **weakly dedicated** to its Claude buffer, so it
  prefers to keep showing Claude but `display-buffer` MAY still reuse it.
- Keep the window a **normal splittable window** (already the case via
  `display-buffer-in-direction`) — no move to Emacs side windows.

Out of scope: opencode integration, multiple/stacked agent windows,
saveable layout presets, the popup output window. This change covers the
single Claude Code runner window only.

## Capabilities

### New Capabilities
- `claude-window-placement`: Deterministic placement of the Claude Code
  buffer — configurable-width, weakly-dedicated, normal (non-side)
  splittable window, with the width clamped to a max fraction of the frame.

### Modified Capabilities
<!-- none: no existing spec's requirements change -->

## Impact

- `elisp/mcp-emacs-run.el`: the `mcp-emacs-run--display` function and the
  window-size customs (`mcp-emacs-run-window-width`, plus a new column
  width and max-fraction custom).
- No change to the MCP server tool surface.
- Behavioral change: runner window opens at a char width (default 120,
  clamped) and is weakly dedicated instead of freely reusable.
