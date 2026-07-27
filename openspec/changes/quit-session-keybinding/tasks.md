## 1. Quit command

- [ ] 1.1 Add `mcp-emacs-run-quit-timeout` defcustom (number, seconds, default 10)
- [ ] 1.2 Add `mcp-emacs-run--quit-sequence` defconst = `"\003\003"` (Ctrl-C twice)
- [ ] 1.3 Implement `mcp-emacs-run-quit`: resolve target via `mcp-emacs-run--resolve-session`, send the quit sequence, arm a non-blocking `run-with-timer` for the timeout
- [ ] 1.4 In the timer handler: guard with `buffer-live-p`; force-kill a still-live process via `delete-process`; then `kill-buffer`
- [ ] 1.5 Autoload cookie + message on quit initiation

## 2. Keybinding

- [ ] 2.1 Bind `SPC E q` to `mcp-emacs-run-quit` in the Doom config (separate dotfiles repo) and add it to the `:commands` list

## 3. Tests

- [ ] 3.1 Quit sends `\003\003` to the resolved buffer (stub `--resolve-session` + `eat-term-send-string`)
- [ ] 3.2 No live session → `user-error`, nothing killed (stub `--sessions-list` nil)
- [ ] 3.3 Timeout handler force-kills a still-live process and kills the buffer (stub `run-with-timer` to invoke synchronously; fake process live)
- [ ] 3.4 Timeout handler with an already-dead process only kills the buffer, no error
- [ ] 3.5 Timeout handler with an already-killed buffer is a no-op (no error)

## 4. Verify

- [ ] 4.1 Byte-compile `elisp/mcp-emacs-run.el` clean
- [ ] 4.2 `emacs -Q --batch -L elisp -l test/mcp-emacs-run-test.el` green
- [ ] 4.3 Live check: start a session, `mcp-emacs-run-quit` → CLI exits and buffer disappears within the timeout; a wedged process is force-killed at the timeout
- [ ] 4.4 Update README with the quit command and its timeout custom
