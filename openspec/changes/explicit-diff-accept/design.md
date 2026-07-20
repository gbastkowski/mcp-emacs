## Context

`mcp-emacs-apply-diff` (`elisp/mcp-emacs.el`) opens `ediff-buffers` (Buffer A = the file, Buffer B = the proposal) and cooperatively polls a `result` cell until an `ediff-quit-hook` closure fills it, then returns `applied` / `rejected` / `timeout`. The server is single-threaded synchronous HTTP, so blocking primitives (`recursive-edit`, `y-or-n-p` from the handler) are out; the poll loop yields via `accept-process-output`.

The defect: the quit hook decides `applied` vs `rejected` by comparing Buffer A's text to its entry snapshot. `ediff-buffers` has no native accept/reject — only one quit path (`q`), which merely tears the session down. So the outcome is inferred, and the inference is wrong for the two common cases: accepting the proposal *unchanged* (Buffer A untouched → misread as `rejected`) and editing then abandoning (Buffer A changed → misread as `applied`). The spec's "Accepting the proposal as-is" scenario already expects `applied`.

## Goals / Non-Goals

**Goals:**
- Outcome reflects an explicit human accept/reject action, not a text diff.
- Accept — with or without hand-edits to either side — returns `applied` with Buffer A's final content.
- Reject returns `rejected`, Buffer A unchanged.
- Preserve the cooperative-poll architecture and the tool's name/args/return shape.

**Non-Goals:**
- No transport change, no deferred responses.
- No named diff tabs / close-all (that was the larger option, declined).
- No auto-save of the file on accept (unchanged: return content, human saves).

## Decisions

### D1: Explicit accept/reject commands bound in the ediff control keymap
`ediff-buffers` offers no accept concept, so provide one. In the ediff startup hook (where we already grab `ediff-control-buffer`), install **buffer-local** key bindings in the control buffer:
- accept → command that, if accepting, copies Buffer B's content into Buffer A (so "accept as-is" applies the proposal), sets `result` to `applied`, and quits the session.
- reject → command that sets `result` to `rejected` and quits without touching Buffer A.

The human resolves via these keys instead of bare `q`. Rationale: makes the decision a first-class action, decoupled from whether text changed. Ediff's own copy commands (`a`/`b`) let the human hand-merge before accepting; accept then reads Buffer A's *current* content, so hand-edits are honoured.

*Alternatives considered:*
- Infer from buffer change (status quo) — the bug; rejected.
- `y-or-n-p` in the quit hook (claude-code-ide's approach) — blocks the server thread; rejected.
- Ediff merge session (`ediff-merge-buffers`) with keep-variants — heavier, changes the UI model and still needs a quit-time decision; rejected for scope.

### D2: Plain `q` maps to reject (safe default)
If the human quits with ediff's normal `q` without choosing accept, treat it as `rejected`. Rationale: abandoning a review should never silently apply a proposal; reject is the conservative outcome and matches "did not accept."

### D3: "Accept" defines the applied content as Buffer A after copy
On accept, copy Buffer B → Buffer A first (unless the human already merged into A), then return Buffer A's content. This makes accept-as-is apply the full proposal and accept-after-edit apply the edited result, satisfying both the "as-is" and "edits before accepting" scenarios with one path. Buffer A is not saved to disk (unchanged policy).

### D4: Keep the `result` cell + poll loop
The accept/reject commands set the same per-call `result` cell the poll loop already watches; the loop and timeout are unchanged. Only the *source* of the decision moves from the quit hook's text comparison to the explicit commands.

## Risks / Trade-offs

- [Human uses ediff's own `a`/`b`/`x` copy keys, then bare `q`] → `q` = reject (D2); their copies into A are discarded because reject restores nothing but also applies nothing — acceptable: reject means reject. Document that accept is the key that commits.
- [Key binding collides with an ediff command] → choose keys not bound in `ediff-mode-map` for accept/reject, or wrap so the accept/reject action is unambiguous; verify against the live ediff keymap during implementation.
- [Buffer A modified on disk externally mid-session] → out of scope; same exposure as today.
- [Accept copies B→A but user had hand-merged A] → prefer A's current content when the human has edited A; otherwise copy B. Resolve the exact precedence in implementation and cover with a test.

## Migration Plan

Behavioural change only; no data migration. Rollback = revert the commit. Communicated as BREAKING in the proposal (accept-unchanged and edit-then-reject flip outcomes).

## Open Questions

- Exact accept/reject keys (e.g. `C-c C-c` / `C-c C-k`, or single `a`/`r`) — pick during implementation against the live `ediff-mode-map` to avoid clobbering ediff navigation.
- Whether to surface the chosen keys in the ediff quit help / a one-line message when the session starts, so the human knows how to accept vs reject.
