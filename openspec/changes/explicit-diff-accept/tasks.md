## 1. Explicit accept/reject in the ediff session

- [ ] 1.1 In the `ediff-buffers` startup hook of `mcp-emacs-apply-diff`, bind buffer-local accept and reject commands in the control buffer's keymap; pick keys not already bound in `ediff-mode-map` (verify against the live keymap).
- [ ] 1.2 Reject command: set the `result` cell to `rejected` and quit the session (`ediff-really-quit`), leaving Buffer A untouched.
- [ ] 1.3 Accept command: apply the proposal to Buffer A (copy Buffer B → A unless the human has hand-edited A, in which case keep A), set `result` to `applied`, then quit.
- [ ] 1.4 Map ediff's plain `q` quit to the reject outcome (safe default) so abandoning the session never applies the proposal.
- [ ] 1.5 Remove the old buffer-content-comparison logic from the quit hook; the outcome now comes only from the explicit commands.

## 2. Result handling

- [ ] 2.1 `applied` returns `"Status: applied\n<final Buffer A content>"`; `rejected` returns `"Status: rejected"`; timeout path unchanged.
- [ ] 2.2 Confirm the cooperative poll loop and timeout still resolve correctly against the new signal source.

## 3. Discoverability

- [ ] 3.1 On session start, message the human which keys accept vs reject (one line), so the flow is obvious.

## 4. Tests

- [ ] 4.1 Accept-unchanged → `applied` with the proposed content (previously misreported as `rejected`).
- [ ] 4.2 Reject → `rejected`, buffer unchanged.
- [ ] 4.3 Edit-proposal-then-accept → `applied` with edited content.
- [ ] 4.4 Quit-without-accept → `rejected`.
- [ ] 4.5 Drive the accept/reject commands via a stubbed/headless ediff (or by invoking the bound commands directly on a constructed session) so tests stay non-interactive.

## 5. Docs & checks

- [ ] 5.1 Update the `apply_diff` tool description if it implies change-detection semantics.
- [ ] 5.2 README: note how to accept vs reject in the diff review, if documented there.
- [ ] 5.3 Byte-compile clean; all tests pass.
- [ ] 5.4 Verify live in the running Emacs: accept-as-is, reject, edit-then-accept, plain-q.
