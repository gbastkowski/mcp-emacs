## 1. Buffer naming and numbering

- [x] 1.1 Change `mcp-emacs-run--buffer-name` to `(root n)` → `*claude:<project>:<n>*`
- [x] 1.2 Add `mcp-emacs-run--next-number (root)`: lowest positive int not in use by a live session of that project

## 2. Session discovery and resolution

- [x] 2.1 Add `mcp-emacs-run--sessions-list`: return live buffers whose name matches `\`\*claude:.+:[0-9]+\*\'`
- [x] 2.2 Add `mcp-emacs-run--buffer-project` helper: resolve a runner buffer's project root from its `default-directory`
- [x] 2.3 Add `mcp-emacs-run--resolve-session`: partition candidates into the 4 tiers (same/other project × visible/hidden), take first non-empty tier, `completing-read` when >1, `user-error` when none
- [x] 2.4 Disambiguate picker labels by buffer name when two projects share a display name

## 2. Send path

- [x] 3.1 Rename low-level send to `mcp-emacs-run--send-to-buffer (buf string)` (no resolution)
- [x] 3.2 Add `mcp-emacs-run--send (string)` that resolves once then calls `--send-to-buffer`
- [x] 3.3 Update all single-keystroke `send-*` commands to call `mcp-emacs-run--send` with no root
- [x] 3.4 Update `mcp-emacs-run-send-prompt` to resolve once and send text + `\r` to the same buffer

## 4. Commands and registry removal

- [x] 4.1 Remove `mcp-emacs-run--sessions` defvar and `mcp-emacs-run--live-buffer`; drop `puthash` in `--launch`
- [x] 4.2 Drop `mcp-emacs-run`; add `mcp-emacs-run-new` (always launch fresh numbered + display); keep `-start` (numbered, no display)
- [x] 4.3 Rewrite `-list`, `-switch`, `-kill`, `-toggle` to use `--sessions-list` / `--resolve-session`; drop `remhash`; multi-session `-kill`/`-toggle` use a picker
- [x] 4.4 Update `-continue` / `-resume` to launch numbered sessions
- [x] 4.5 Rebind `SPC E e` from `mcp-emacs-run` to `mcp-emacs-run-new` in the Doom config (separate dotfiles repo)

## 5. Tests

- [x] 5.1 Update `buffer-name` test for the `:<n>` suffix; add `--next-number` tests (fresh=1, next=2, refill gap)
- [x] 5.2 Remove registry-specific tests (`puthash`/`--live-buffer`/`clrhash` setups)
- [x] 5.3 Add resolution tests stubbing `buffer-list` + `get-buffer-window`: single same-project visible; one-of-many same-project; visible-beats-hidden; cross-project fallback; ambiguous → picker; none → user-error
- [x] 5.4 Add a test that `send-prompt` resolves once (picker invoked at most once) for an ambiguous tier
- [x] 5.5 Adjust headless launch tests that asserted registration to assert discovery via `--sessions-list`

## 6. Verify

- [x] 6.1 Byte-compile `elisp/mcp-emacs-run.el` clean
- [x] 6.2 `emacs -Q --batch -L elisp -l test/mcp-emacs-run-test.el` green
- [x] 6.3 Live check in the running Emacs (stubbed eat): two sessions `:1`/`:2`; ambiguous send prompts once and delivers text+return; single visible session auto-resolves; kill `:1` → next number refills 1; cross-project fallback resolves the visible other-project session
