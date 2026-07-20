## Why

The `apply_diff` tool already runs an interactive ediff session that blocks cooperatively and returns `applied` / `rejected` / `timeout`.
But it infers the outcome by comparing Buffer A's text against its entry state: "applied" means "the buffer changed."
This misreads the two most common cases — accepting the proposal without hand-editing, and rejecting after making an edit — and contradicts the tool's own spec, whose "Accepting the proposal as-is" scenario expects `applied`.
The human's accept/reject decision should be explicit, not guessed from whether the text happens to differ.

## What Changes

- Determine the `apply_diff` outcome from an explicit human accept/reject action during the ediff session, not from whether Buffer A's content changed.
  - Accepting (with or without hand-edits) returns `applied` with the final Buffer A content.
  - Rejecting returns `rejected` and leaves the buffer unchanged.
  - Timeout behaviour is unchanged.
- Keep the cooperative-poll architecture (no `recursive-edit`, no blocking prompt); the accept/reject signal is captured by the ediff quit/registration hooks and resolved through the existing `result` cell.
- **BREAKING** (behavioural): a session where the human accepts the proposal unchanged now returns `applied` instead of `rejected`; a session where the human edits then rejects now returns `rejected` instead of `applied`.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `ide-integration-tools`: the "Interactive diff/apply tool presents a proposal via ediff" requirement is clarified so the outcome is driven by an explicit accept/reject decision rather than by buffer-content comparison.

## Impact

- `elisp/mcp-emacs.el`: `mcp-emacs-apply-diff` outcome detection (the ediff quit hook and `result` handling).
- `test/`: add coverage for accept-unchanged → `applied` and edit-then-reject → `rejected`.
- No transport or tool-schema change; `apply_diff` name, arguments, and return shape are unchanged.
- Addresses #10.
