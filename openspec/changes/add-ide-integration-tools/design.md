## Context

`mcp-emacs` is a single-threaded, event-driven MCP server running inside Emacs.
Tool handlers run on the Emacs main thread; long-running handlers must yield to
the event loop (via `accept-process-output`) so other tool calls and human edits
keep flowing — the pattern already established by
`mcp-emacs-org-task-wait-for-change`.

`claude-code-ide.el` implements an interactive diff via `ediff`, but wraps it in
per-session, per-tab bookkeeping tied to its Claude-Code-CLI IDE protocol
(sessions keyed by project dir, "quit-from-claude" remote-quit handling, side
windows for the Claude buffer). None of that applies here: mcp-emacs has no
notion of a Claude side window or a remote CLI that can quit the diff. The
design goal is the same interaction (review a proposed change in `ediff`,
edit/accept/reject) with the minimum machinery that fits mcp-emacs's stateless,
pull-model tools.

## Goals / Non-Goals

**Goals:**
- Provide `apply_diff`: show original vs proposed in `ediff`, let the human
  edit/accept/reject, and return `applied` (with final content) / `rejected` /
  `timeout`.
- Block cooperatively with a bounded timeout, reusing the existing
  `accept-process-output` wait pattern so the server stays responsive.
- Provide `list_open_editors` and `check_document_dirty` as small, stateless
  queries over Emacs's live buffers.
- Keep every tool harness-agnostic: plain MCP over the existing HTTP transport,
  no client-specific handshake.

**Non-Goals:**
- The Claude-Code-CLI IDE WebSocket protocol, lockfile/env handshake, terminal
  runner, and live selection push notifications.
- Multi-session / per-project diff bookkeeping and remote (client-initiated)
  quit of the ediff session.
- Three-way merge or conflict resolution beyond what `ediff` offers by default.

## Decisions

### D1: Reuse the `accept-process-output` cooperative-wait pattern
The `apply_diff` handler starts the `ediff` session, then spins a wait loop
identical in shape to `mcp-emacs-org-task-wait-for-change`: while the outcome is
still pending and the deadline has not passed, call
`(accept-process-output nil poll-interval)`. This keeps the single-threaded
server responsive to other tool calls and to the human's interaction with ediff.

- **Alternative considered:** deferring the response via an idle timer and a
  second poll tool (as some MCP servers do). Rejected — it doubles the tool
  surface and contradicts the blocking model the user chose and that
  `wait_for_change` already establishes.

### D2: Signal the outcome through a per-session result cell + `ediff-quit-hook`
Before launching ediff, bind a fresh result cell (a cons or a `let`-scoped
variable captured in the hook closures). Install a buffer-local
`ediff-quit-hook` on the control buffer that records the outcome, then quits.
The wait loop reads this cell.

- Buffer A = the file's current content (via `find-file-noselect`), Buffer B =
  the proposed content in a temporary buffer.
- **Accept** = the human copies/merges the desired result into Buffer A and it
  ends up modified to the accepted content, or an explicit accept action is
  taken; the hook captures Buffer A's final text and marks `applied`.
- **Reject** = the human quits ediff without accepting; the hook marks
  `rejected` and Buffer A is left as it was on entry.
- **Alternative considered:** claude-code-ide's session/tab hash tables. Rejected
  as overkill — mcp-emacs handles one interactive diff at a time per call, and
  the result cell is captured in the closure, so no global registry is needed.

### D3: Determine `applied` vs `rejected` by Buffer A's final content
Rather than intercept individual ediff commands, compare Buffer A's content at
quit time against its content at entry. If it changed (the human merged the
proposal, wholly or partially), return `applied` with the new content and mark
the buffer for the human to save (do not auto-save — saving stays the human's
job, consistent with the existing `save_buffer`/no-auto-save rule). If unchanged,
return `rejected`.

- **Alternative considered:** requiring a dedicated "accept" keybinding. Rejected
  as an extra thing the human must learn; content-diff detection works with
  plain ediff usage.

### D4: Timeout abandons the session cleanly
On timeout the handler force-quits any still-live ediff control buffer
(`ediff-really-quit` guarded by `ignore-errors`, falling back to killing the
control buffer), restores the window configuration saved before launch, leaves
Buffer A unmodified, and returns `timeout`. Default and max timeouts reuse /
mirror the existing `org-task-wait` customs.

### D5: `list_open_editors` and `check_document_dirty` are pure queries
- `list_open_editors`: iterate `(buffer-list)`, keep buffers with a non-nil
  `buffer-file-name`, return `path`, buffer `name`, and `(buffer-modified-p)`.
- `check_document_dirty`: resolve the buffer visiting the given path; return its
  `buffer-modified-p`, or "not open" when no live buffer visits it.
Both are registered as tool descriptors alongside the existing ones and need no
waiting or state.

## Risks / Trade-offs

- **Content-diff outcome detection can misclassify a no-op accept** (human
  accepts but the accepted content equals the original) → such a case is
  indistinguishable from reject and returns `rejected`; acceptable because the
  file ends in the same state either way.
- **Only one interactive diff per call; concurrent `apply_diff` calls could
  interleave ediff sessions** → the result cell is per-call, but two overlapping
  ediff sessions would confuse the human; document that `apply_diff` is meant to
  be used one at a time (the blocking model naturally serializes a single
  client).
- **`ediff` modifies window configuration** → mitigated by saving and restoring
  the window configuration around the session (D4).
- **A wait that never resolves** → bounded by the timeout (D4), so the call
  cannot hang the client indefinitely; the server itself never blocks (D1).

## Open Questions

- Should `apply_diff` optionally auto-save Buffer A on `applied`, or always
  leave saving to the human? Current design: always leave it to the human,
  matching the existing no-auto-save convention; revisit if a caller needs the
  file on disk immediately (they can call `save_buffer`).
