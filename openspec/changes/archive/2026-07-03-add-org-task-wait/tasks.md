## 1. Change token in read output

- [x] 1.1 Add a helper to compute the change token for a session file (its buffer's `buffer-chars-modified-tick`)
- [x] 1.2 Extend `mcp-emacs-org-task-read` to include a `Token: <n>` line in the structured view
- [x] 1.3 Verify the token advances after a buffer edit (read, edit, read → different token)

## 2. Wait helper (mcp-emacs.el)

- [x] 2.1 Add `mcp-emacs-org-task-wait-for-change` (path, token, timeout): open/resolve the buffer, apply default/cap to timeout
- [x] 2.2 Return immediately when the current tick already differs from the baseline token (no missed edits)
- [x] 2.3 Otherwise loop on `accept-process-output` at a poll interval until the tick advances or the timeout elapses (event-loop friendly)
- [x] 2.4 Return a result carrying the change flag, the new token, and the current session view; fail soft on invalid path/timeout

## 3. Wait tool (org-task-wait)

- [x] 3.1 Add `org_task_wait_for_change` tool plist (path required; token and timeout optional) to `mcp-emacs-server--tools`
- [x] 3.2 Handler calls the wait helper and returns its plain-text result

## 4. Testing & docs

- [x] 4.1 Reload into the live daemon; confirm `org_task_session` now emits a token
- [x] 4.2 Test change-during-wait: start a wait, edit the buffer from another call, confirm it wakes with `changed`
- [x] 4.3 Test immediate return: pass a stale token, confirm it returns at once
- [x] 4.4 Test timeout: pass the current token, no edit, confirm it returns "no change" within the timeout and Emacs stayed responsive
- [x] 4.5 Update README.md tool table and the "Org task session sync" section with the cooperative-loop tool
