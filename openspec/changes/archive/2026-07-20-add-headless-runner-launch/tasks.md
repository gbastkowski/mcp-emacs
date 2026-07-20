## 1. Launch helper

- [x] 1.1 Add optional `no-display` param to `mcp-emacs-run--launch` (signature `(root no-display &rest extra-switches)`); skip `mcp-emacs-run--display` when non-nil, still register the session and return the buffer.
- [x] 1.2 Update the two existing callers (`mcp-emacs-run`, continue/resume path) to pass `nil` for `no-display`.

## 2. Headless command

- [x] 2.1 Add autoloaded interactive `mcp-emacs-run-start`: reuse a live session without displaying, else launch headless; `message` naming the project and that it started hidden.

## 3. Tests

- [x] 3.1 Test: headless start registers the session buffer and displays no window.
- [x] 3.2 Test: revealing a headless session via toggle/switch displays its buffer.
- [x] 3.3 Test: headless start with an existing live session reuses it and displays no window.

## 4. Wire-up & docs

- [x] 4.1 Bind `mcp-emacs-run-start` under the Doom `SPC E` runner prefix in dotfiles.
- [x] 4.2 Note the headless command in the README runner section.
