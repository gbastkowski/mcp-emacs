## Context

`mcp-emacs-run.el` hosts the Claude Code CLI as a full-screen ANSI TUI inside an `eat` terminal buffer, one primary session per project.
Today `mcp-emacs-explain-selection-in-current-session` builds a reference for the selection and sends `explain <ref>` into that terminal via `eat-term-send-string`.
The response is produced and rendered **by the CLI TUI**, not by Emacs — the terminal owns the output.

The proposal wants: when no window is showing the session buffer, render the explanation in a separate regular split window, formatted as markdown with syntax-highlighted code, no auto-hide, scroll/select/copy.

This exposes a structural fact: the current runner is a **TUI sink**. Emacs feeds it text and never sees the model's reply as data. A popup surface needs the reply *as text* to render it. So the popup cannot simply mirror the TUI session's answer — the two output paths are fundamentally different.

Constraints:
- Emacs 28.1, `eat` is a soft dependency, package stays pure/optional-deps.
- `markdown-mode` provides `gfm-view-mode` and `markdown-fontify-code-blocks-natively` — a new soft dependency for the render layer.
- Related in-flight work on branch `runner-window-not-side` already moved the runner off dedicated side windows to `display-buffer-in-direction`.

## Goals / Non-Goals

**Goals:**
- A reusable Emacs-side primitive that renders markdown text in a dedicated per-kind buffer, shown in a regular split window, read-only, code-fontified, persistent, scroll/select/copy capable.
- Route explain-selection to that primitive when the session buffer is not visible in any window.
- Keep the render primitive caller-agnostic so future callers (diagnostic detail, hover doc, diff preview) reuse it.

**Non-Goals:**
- Not scraping or parsing the TUI terminal output to recover the model's reply.
- No auto-hide / glance-and-dismiss behavior (posframe-style) — explicitly rejected.
- Not changing the MCP tool surface.
- Not building the non-explain callers now (only proving the primitive is reusable).

## Decisions

### Decision: regular split window with a dedicated buffer, not posframe
Use a normal buffer shown via `display-buffer` in a regular split. Gives scroll, region, `M-w` copy, and explicit dismissal for free — all hard reqs.
- **Alternatives:** posframe (child frame) — rejected: no point/mark, awkward copy, clunky scroll, built for auto-hide. Side window — rejected: `runner-window-not-side` is moving away from side windows; also less flexible.

### Decision: render with `gfm-view-mode` + native code fontification
Claude emits GitHub-flavored markdown (tables, fenced code, task lists). `gfm-view-mode` is read-only and pretty; set `markdown-fontify-code-blocks-natively` buffer-local and re-run `font-lock-flush`/`font-lock-ensure` so fenced blocks fontify per language.
- **Alternatives:** md→org conversion — rejected for now: extra conversion step (pandoc/elisp), only worth it if the project standardizes on Org. Plain text — rejected: loses the formatting the proposal asks for.
- **Trade-off:** `markdown-mode` becomes a soft dependency; guard with `require ... nil t` and a clear `user-error` if absent, matching the `eat` pattern.

### Decision: one buffer per kind, reused
Buffer name derived from a kind identifier (e.g. `*mcp-emacs:explain*`). Re-render erases and refills the same buffer and reuses its window. Keeps windows from piling up; matches "ephemeral output at point" usage.
- **Alternative:** fresh buffer per invocation — rejected: N windows/buffers accumulate. History-keeping is not a requirement.

### Decision: sink routing by session-buffer visibility
`mcp-emacs-explain-selection-*` checks `(get-buffer-window session-buffer)`. Visible → send to TUI (current behavior). Not visible → render in popup. No live session at all → report, do not launch (unchanged).

### Decision: how the popup gets the explanation text — the real question
The TUI does not hand Emacs the reply, so the popup path needs its own text source. Options:

1. **Direct headless CLI call for the popup path** — run `claude` (or the query CLI) non-interactively to get markdown to stdout, capture, render. Popup and TUI become independent output channels. Cleanest separation; the popup answer is genuinely Emacs-owned text. Cost: a second invocation path, latency, must confirm the CLI's non-interactive/print mode and flags.
2. **Route via an MCP/agent backend that returns text** — align with the deferred agent-backend abstraction (opencode HTTP returns structured text). Fits the longer-term direction but that abstraction is explicitly deferred.
3. **Scrape the eat terminal** — rejected: brittle, TUI redraws, ANSI noise.

Recommend **option 1** for this change: a headless `claude` print invocation for the popup sink, kept behind a small function so it can later be swapped for the agent backend (option 2) without touching the render primitive. This keeps the render layer (the actual deliverable) decoupled from where the text comes from.

## Risks / Trade-offs

- [Headless CLI print mode uncertain] → Verify the exact non-interactive flag/behavior against the installed `claude` before implementing the popup text source; if unavailable, the render primitive still ships and the routing can fall back to a message until a text source exists.
- [`markdown-mode` missing] → Soft-require and `user-error` with install hint, same as `eat`.
- [`markdown-fontify-code-blocks-natively` set too late → plain code] → Set buffer-local before mode fontifies, then `font-lock-flush`/`font-lock-ensure`.
- [Popup and TUI answers diverge] → Two independent invocations can give different replies. Acceptable: popup is used precisely when the session is not on screen; document that it is a separate query, not a mirror.
- [Latency of a second CLI call] → Show the buffer immediately with a "working…" placeholder, fill on completion.

## Resolved

- **Headless invocation:** `claude -p "<prompt>" --output-format text`, run from the project root via an async process (`make-process`/`start-process`), stdout captured and rendered on the process sentinel. `-p/--print` is the CLI's documented non-interactive mode; `text` output is markdown as-is.
- **Session context:** one-shot query (no `--continue`/`--resume`) for simplicity; the popup is used precisely when the session is off-screen, so it is a separate query, not a mirror of the TUI conversation.

## Open Questions

- None blocking. Permission handling for a headless call in an arbitrary project (tool prompts) is out of scope for explain, which needs no tools; revisit if later callers require tool access.
