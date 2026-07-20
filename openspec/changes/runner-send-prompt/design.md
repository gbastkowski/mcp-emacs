## Context

`mcp-emacs-run.el` launches the Claude CLI in an `eat` terminal, one primary session per project, tracked in `mcp-emacs-run--sessions` (project root → buffer).
Today it can only launch, display, and kill; it cannot feed input to a running session.
claude-code-ide reaches parity here through `claude-code-ide--terminal-send-string` (backend-dispatched) plus `send-prompt` / `send-escape` / `send-return`, and `insert-at-mentioned` for pushing a selection into the prompt.

The eat terminal exposes a single primitive we need: `(eat-term-send-string TERMINAL STRING)`, where `TERMINAL` is the buffer-local `eat-terminal` object of the eat buffer. claude-code-ide's eat branch does exactly `(eat-term-send-string eat-terminal string)`, sends `"\e"` for escape and `"\r"` for return.

## Goals / Non-Goals

**Goals:**
- Send an arbitrary prompt string to the current project's live session and submit it.
- Send an escape/interrupt and a non-submitting newline to that session.
- Build a reference for the current selection: `@relative/path:startline-endline` for a file-backed buffer (`:line` with no active region), falling back to the inline selected text for non-file buffers.
- Provide `mcp-emacs-explain-selection-in-current-session` as the first consumer.
- Target only an existing session; report clearly when none exists.

**Non-Goals:**
- No terminal backend other than eat (matches the runner's existing eat-only stance).
- No MCP-server-side tool — these are Emacs-side runner commands the *user* invokes, not tools the agent calls.
- No selection *push-tracking* / notifications (that is the separate selection-push gap, out of scope).
- No new keybindings shipped in this repo (documented for the user's Doom config).

## Decisions

### D1: One low-level send helper, three thin commands
Add `mcp-emacs-run--send (root string)` that looks up the live buffer for `root`, reads its buffer-local `eat-terminal`, and calls `eat-term-send-string`. Build on it:
- `mcp-emacs-run-send-prompt (text)` → send `text` then `"\r"`.
- `mcp-emacs-run-send-escape` → send `"\e"`.
- `mcp-emacs-run-send-newline` → send the newline-without-submit sequence.

Rationale: mirrors claude-code-ide's structure, keeps backend detail (`eat-terminal`, control chars) in one place.
*Alternative considered:* a public MCP tool so the agent could self-prompt — rejected, this is a human-driven action and the runner is deliberately not an MCP surface.

### D2: Newline-without-submit
The CLI treats `\r` as submit and a bare `\n` as a literal newline in the prompt editor. `send-newline` sends `"\n"`; verified against the running CLI — it inserts a newline without submitting.

### D3: Reference builder — prefer @mention, fall back to inline
`mcp-emacs-run--selection-reference` returns a string:
- Buffer visits a file → `@PATH:START[-END]`, where `PATH` is relative to the project root (so it matches how the CLI resolves at-mentions), `START`/`END` are the region's line span (1-based), or a single `:LINE` at point when no region is active.
- Buffer has no file → the region text verbatim (or, with no region, the current line), so the command still works in scratch/compilation/etc.

Rationale: at-mentions keep prompts small and let the CLI read current on-disk content; inline text is the robust fallback. Line numbers use Emacs' 1-based `line-number-at-pos`.
*Alternative considered:* always inline text — rejected, large selections bloat the prompt and go stale; always @mention — rejected, breaks on non-file buffers.

### D4: `explain-selection` composition
`mcp-emacs-explain-selection-in-current-session` = `(mcp-emacs-run-send-prompt (concat "explain " (mcp-emacs-run--selection-reference)))` against the current project's session. No session → `user-error`, consistent with `mcp-emacs-run-kill`.

### D5: Session targeting
All commands resolve the project via the existing `mcp-emacs-run--project-root` and reuse `mcp-emacs-run--live-buffer`. They never launch: if there is no live session they signal a `user-error`. This keeps "send" side-effect-free w.r.t. process creation and avoids surprising the user with a fresh CLI on an explain.

## Risks / Trade-offs

- [Newline sequence may differ across CLI versions/line editors] → isolate in `send-newline`; verify against the live CLI during implementation; the control char lives in one place so a fix is one line.
- [At-mention path resolution depends on the CLI's cwd = project root] → the runner already launches with `default-directory` = project root, so relative paths line up; document the assumption.
- [`eat-term-send-string` on a dead or non-eat buffer] → `mcp-emacs-run--live-buffer` already prunes dead buffers; guard that `eat-terminal` is non-nil and signal a clear error otherwise.
- [Sending to a session mid-response] → sending input while the CLI is busy is the user's choice (same as typing); no special handling.

## Open Questions

- Should `send-prompt` optionally *not* submit (leave the text in the prompt for the user to edit)? Deferred; `explain` wants immediate submit. Could add a prefix-arg later.
