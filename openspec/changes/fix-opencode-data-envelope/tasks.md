## 1. Unwrap the data envelope

- [x] 1.1 In `opencode-client--request`, after parsing, unwrap: if the result is an alist with a `data` key, return its value; otherwise return the result unchanged.
- [x] 1.2 Confirm callers (`--sessions`, `create-session`, `switch-session`, single-session fetch, message render, prompt) now read the right shape with no per-caller change.

## 2. Verify

- [x] 2.1 Byte-compile `elisp/opencode-client.el` cleanly.
- [x] 2.2 Batch tests (stub `plz`): wrapped-object response unwraps to the inner object; wrapped-list unwraps to the inner list; flat health response passes through unchanged.
- [x] 2.3 Update README opencode section if any user-facing behavior notes are needed (likely none).
