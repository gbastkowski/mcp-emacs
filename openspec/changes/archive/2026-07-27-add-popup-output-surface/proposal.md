## Why

AI IDE features that produce formatted output (starting with explain-selection) currently push everything into the runner session terminal.
When the session buffer is not visible in any window, the result lands off-screen and the user has to hunt for it.
There is no reusable surface for rendering ephemeral, formatted AI output near the code the user is looking at.

## What Changes

- Add a reusable popup output surface: a command that takes markdown content and renders it in a dedicated buffer shown in a regular split window.
- Render content with `gfm-view-mode` (read-only, pretty) and native code-block fontification, so Claude's markdown — headings, tables, fenced code — displays formatted and syntax-highlighted.
- No auto-hide. The surface is a normal window/buffer, so the user can scroll, select, and copy, and dismiss it explicitly.
- Reuse one buffer per output kind: a new render of the same kind replaces the previous content in the same window.
- Route explain-selection output through the popup when no window is currently showing the project's session buffer; keep sending to the session when its buffer is visible.

## Capabilities

### New Capabilities
- `popup-output-surface`: renders markdown text in a dedicated buffer shown in a regular split window, formatted read-only with native code fontification, persistent (no auto-hide), scroll/select/copy capable, reused per output kind.

### Modified Capabilities
- `runner-send-prompt`: explain-selection chooses its output sink based on session-buffer visibility — session terminal when its window is visible, popup output surface otherwise.

## Impact

- `elisp/` — new popup render module plus routing in the explain-selection command path (`elisp/mcp-emacs-run.el` and/or a new file).
- Depends on `markdown-mode` (provides `gfm-view-mode` and `markdown-fontify-code-blocks-natively`), already a common Emacs package.
- No MCP tool surface change required; this is Emacs-side display behavior.
