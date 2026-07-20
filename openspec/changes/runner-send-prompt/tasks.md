## 1. Low-level send

- [ ] 1.1 Add `mcp-emacs-run--send (root string)`: resolve the live buffer via `mcp-emacs-run--live-buffer`, read its buffer-local `eat-terminal`, `user-error` if no session or no terminal, else `eat-term-send-string`.
- [ ] 1.2 Add `declare-function` for `eat-term-send-string` and a `defvar` reference for `eat-terminal`.

## 2. Send commands

- [ ] 2.1 `mcp-emacs-run-send-prompt (text)` — interactive (read string), send `text` then `"\r"`.
- [ ] 2.2 `mcp-emacs-run-send-escape` — send `"\e"`.
- [ ] 2.3 `mcp-emacs-run-send-newline` — send the newline-without-submit sequence; verify `"\n"` vs shift-enter escape against the running CLI.
- [ ] 2.4 Autoload cookies on the three commands.

## 3. Reference builder

- [ ] 3.1 Add `mcp-emacs-run--selection-reference`: file buffer → `@<project-relative-path>:<start>[-<end>]` using 1-based `line-number-at-pos`; single `:line` when no region; non-file buffer → region text (or current line) verbatim.
- [ ] 3.2 Path relative to `mcp-emacs-run--project-root`.

## 4. Explain command

- [ ] 4.1 `mcp-emacs-explain-selection-in-current-session` — build reference, `mcp-emacs-run-send-prompt (concat "explain " ref)`; autoload cookie.

## 5. Tests

- [ ] 5.1 Unit-test `mcp-emacs-run--selection-reference` headless: file-with-region, file-no-region, non-file — cover all three spec scenarios.
- [ ] 5.2 Test the no-session guard: send command in a project with no live session signals `user-error` and launches nothing (stub eat as in existing headless tests).
- [ ] 5.3 Test `--send` delivers the string to a stubbed terminal.

## 6. Docs & checks

- [ ] 6.1 README runner section: document the send/explain commands.
- [ ] 6.2 Byte-compile clean; all tests pass.
- [ ] 6.3 Note suggested Doom `SPC E` bindings for explain in dotfiles (out of repo; mention in change summary).
