## 1. Keystroke sender commands

- [x] 1.1 Add `mcp-emacs-run-send-return` sending `"\r"` to the project's live session.
- [x] 1.2 Add `mcp-emacs-run-send-1`, `-send-2`, `-send-3` sending `"1"`/`"2"`/`"3"`.
- [x] 1.3 Add `mcp-emacs-run-send-shift-tab` sending `"\e[Z"`.
- [x] 1.4 Add `mcp-emacs-run-send-up` (`"\e[A"`) and `-send-down` (`"\e[B"`).
- [x] 1.5 Each command is interactive, `;;;###autoload`, and a thin wrapper over `mcp-emacs-run--send` so the no-live-session guard is inherited.

## 2. Verify

- [x] 2.1 Byte-compile `elisp/mcp-emacs-run.el` cleanly.
- [x] 2.2 Batch tests: each command delivers the exact expected string to the session terminal (stub `eat-term-send-string`), and errors with no live session.
- [x] 2.3 Update README with the new send commands.

## 3. Keybindings (user dotfiles, out of repo)

- [ ] 3.1 Bind the new commands under the Doom `SPC E` prefix in the mcp-emacs module and add them to the `:commands` autoload list.
