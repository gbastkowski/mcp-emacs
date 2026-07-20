## Why

Claude's TUI frequently asks for a single keystroke — accept/reject menus (1/2/3), a bare Return to accept a default, Shift-Tab to cycle mode, arrow keys to navigate. Today the runner only exposes prompt submit, escape, and newline, so driving those prompts from Emacs means switching into the terminal by hand. Other Emacs integrations (e.g. `claude-code.el`) provide these one-key senders and they are convenient to bind.

## What Changes

- Add interactive commands that send a single keystroke to the current project's live runner session, building on the existing send primitive:
  - `mcp-emacs-run-send-return` — bare carriage return (accept default / submit).
  - `mcp-emacs-run-send-1` / `-send-2` / `-send-3` — the digits `1`/`2`/`3` for numbered menus.
  - `mcp-emacs-run-send-shift-tab` — `\e[Z` to cycle Claude's mode.
  - `mcp-emacs-run-send-up` / `-send-down` — arrow keys `\e[A` / `\e[B` for history/menu navigation.
- All require a live session and never launch one, matching the existing send commands.

## Capabilities

### New Capabilities

### Modified Capabilities
- `runner-send-prompt`: adds a requirement for single-keystroke input commands (return, digits 1–3, shift-tab, arrow up/down) that feed one key to the live session.

## Impact

- `elisp/mcp-emacs-run.el` — new interactive commands over the existing `mcp-emacs-run--send` helper.
- Doom module keybindings in the user's dotfiles (out of this repo).
- No MCP tool surface change.
