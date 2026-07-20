## Why

The runner shows its buffer in a dedicated side window.
Side windows reduce frame layout flexibility: they can't be split, are skipped by ordinary window navigation, survive `delete-other-windows`, and force a fixed edge placement — awkward when the user wants to rearrange the frame.

## What Changes

- Display the runner in an ordinary (non-dedicated) window placed in a configurable direction (default `right`) via `display-buffer-in-direction`, instead of a dedicated side window.
- Replace the `mcp-emacs-run-window-side` option with `mcp-emacs-run-window-direction` (`right`/`left`/`above`/`below`); keep a size hint (window width/height).
- **BREAKING** (config only): `mcp-emacs-run-window-side` is removed; users who set it move to `mcp-emacs-run-window-direction`.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `claude-runner`: the "Manage the runner window" requirement changes from side-window placement to an ordinary window placed in a configurable direction.

## Impact

- `elisp/mcp-emacs-run.el`: `mcp-emacs-run--display`, the window defcustoms.
- `test/mcp-emacs-run-test.el`: window-reveal tests still hold (they assert a window exists, not that it is a side window).
- Doom dotfiles: no change (bindings unaffected).
