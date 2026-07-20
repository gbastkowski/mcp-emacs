## Context

The runner already has `mcp-emacs-run--send`, which delivers a raw string to the project's live eat terminal and signals a `user-error` when there is no live session. The existing `mcp-emacs-run-send-escape` / `-send-newline` commands are one-line wrappers over it. The new keystroke senders are the same shape.

## Goals / Non-Goals

**Goals:**
- Add one-key sender commands (return, 1/2/3, shift-tab, up/down) as thin wrappers over the existing send primitive.

**Non-Goals:**
- No new backend abstraction (eat only, as today).
- No key *binding* in this repo — bindings live in the user's Doom module.
- No changes to the send primitive itself.

## Decisions

### Decision: thin wrappers over `mcp-emacs-run--send`
Each command is `(mcp-emacs-run--send (mcp-emacs-run--project-root) STR)` with the right byte sequence. Reuses the existing live-session guard for free, so the no-session behavior is identical to the other send commands.

Escape sequences:
- return → `"\r"`
- digits → `"1"` / `"2"` / `"3"`
- shift-tab → `"\e[Z"`
- up → `"\e[A"`, down → `"\e[B"`

### Decision: no auto-repeat / prefix-arg handling
Keep each command a single keystroke; users bind them and press again to repeat. Matches `claude-code.el`'s simple senders.

## Risks / Trade-offs

- [Terminal may interpret sequences differently across CLI versions] → These are standard xterm sequences the CLI already handles from a real terminal; low risk. Verified shape against `claude-code.el`.

## Open Questions

- None.
