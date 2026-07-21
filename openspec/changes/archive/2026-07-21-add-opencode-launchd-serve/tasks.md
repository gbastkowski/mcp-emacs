## 1. Command-based password

- [x] 1.1 Add `opencode-client-password-command` defcustom (shell command string or nil).
- [x] 1.2 Add `opencode-client--password`: return `opencode-client-password` if set; else run `opencode-client-password-command` via the shell and return trimmed stdout; else nil.
- [x] 1.3 `opencode-client--headers` uses `opencode-client--password` instead of the raw variable.

## 2. launchd kickstart start mode

- [x] 2.1 Add `opencode-client-launchd-label` defcustom (string or nil).
- [x] 2.2 In `opencode-client-serve`, when the label is set, start via `launchctl kickstart gui/<uid>/<label>` (uid from `(user-uid)`); otherwise keep the `start-process` fallback. Health-poll unchanged.

## 3. Verify

- [x] 3.1 Byte-compile cleanly.
- [x] 3.2 Batch tests: `--password` returns the direct value when set; runs the command and trims when only the command is set; nil when neither; and `--headers` includes basic auth iff a password resolves.
- [x] 3.3 Update README opencode section: password-command and launchd label options, and the "run opencode as a launchd agent that outlives Emacs" workflow.
