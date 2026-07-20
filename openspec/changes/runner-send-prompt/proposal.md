## Why

The runner (`mcp-emacs-run.el`) is launch-only: once the CLI is running in its eat terminal, there is no way to drive it from elsewhere in Emacs.
claude-code-ide provides `send-prompt`, `send-escape`, `insert-newline`, and `insert-at-mentioned`; these are parity gaps blocking its retirement (issues #11, #12).
Concretely, the user cannot select code, hit a key, and have the running session explain it — they must copy-paste into the terminal.

## What Changes

- Add runner commands to drive the current project's live CLI terminal:
  - send a prompt string (submitting it to the CLI)
  - send an escape / interrupt
  - insert a newline into the prompt without submitting
- Add an at-mention reference builder: for a file-backed buffer produce `@relative/path:startline-endline` (or `:line` with no region); for a non-file buffer fall back to the inline selected text.
- Add `mcp-emacs-explain-selection-in-current-session`: build a reference for the region (or point) and send `explain <ref>` to the project's session, as the first consumer of the above.

All of this targets an existing live session for the current project; if none exists, the commands report that rather than launching silently.

## Capabilities

### New Capabilities
- `runner-send-prompt`: driving a live runner session from Emacs — sending a prompt, escape, and newline to the CLI terminal; building an at-mention/inline reference for the current selection; and the `explain-selection` command built on both.

### Modified Capabilities
<!-- none: the existing claude-runner spec covers launch/window/session lifecycle; this adds a distinct interaction capability rather than changing those requirements. -->

## Impact

- `elisp/mcp-emacs-run.el`: new interactive commands and a reference-builder helper; needs to reach into the eat terminal buffer to feed input.
- Depends on `eat` terminal input APIs (already a soft dependency).
- `test/mcp-emacs-run-test.el`: reference-builder is pure and unit-testable headless; terminal-send is stubbed like the existing headless launch tests.
- Doom dotfiles: optionally new `SPC E` bindings for the explain command (out of scope here; documented for the user).
- Closes #11 and #12.
