## 1. Quit command

- [x] 1.1 Add `mcp-emacs-run-quit-timeout` defcustom (number, seconds, default 10)
- [x] 1.2 Add `mcp-emacs-run--quit-sequence` defconst = `"\003\003"` (Ctrl-C twice)
- [x] 1.3 Implement `mcp-emacs-run-quit`: resolve target via `mcp-emacs-run--resolve-session`, send the quit sequence, arm a non-blocking `run-with-timer` for the timeout
- [x] 1.4 In the timer handler: guard with `buffer-live-p`; force-kill a still-live process via `delete-process`; then `kill-buffer`
- [x] 1.5 Autoload cookie + message on quit initiation

## 2. Keybinding

- [x] 2.1 Bind `SPC E q` to `mcp-emacs-run-quit` in the Doom config (separate dotfiles repo) and add it to the `:commands` list

## 3. Tests

- [x] 3.1 Quit sends `\003\003` to the resolved buffer (stub `--resolve-session` + `eat-term-send-string`)
- [x] 3.2 No live session → `user-error`, nothing killed (stub `--sessions-list` nil)
- [x] 3.3 Timeout handler force-kills a still-live process and kills the buffer (stub `run-with-timer` to invoke synchronously; fake process live)
- [x] 3.4 Timeout handler with an already-dead process only kills the buffer, no error
- [x] 3.5 Timeout handler with an already-killed buffer is a no-op (no error)

## 4. Verify

- [x] 4.1 Byte-compile `elisp/mcp-emacs-run.el` clean
- [x] 4.2 `emacs -Q --batch -L elisp -l test/mcp-emacs-run-test.el` green
- [ ] 4.3 Live check (deferred — user will verify): start a session, `mcp-emacs-run-quit` → CLI exits and buffer disappears within the timeout; a wedged process is force-killed at the timeout
- [x] 4.4 Update README with the quit command and its timeout custom
