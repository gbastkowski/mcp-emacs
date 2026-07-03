## Context

The org-task-sync feature (see [[org-task-session]] / [[org-task-update]]) makes an Org file a shared human/AI workspace, but the AI only sees human edits when it re-reads on its own initiative. Claude Code has no inbound API, so a true interrupt-push is impossible. This change adds the missing piece for a *cooperative loop*: a tool the AI calls to wait for the human's next edit.

Key constraint: Emacs runs single-threaded. A naive blocking wait would freeze the daemon and every other tool call. The wait must yield to the event loop.

## Goals / Non-Goals

**Goals:**
- One MCP tool, `org_task_wait_for_change`, that blocks up to a timeout and returns when the session task file is edited.
- Stay responsive: human edits and other MCP calls process during the wait.
- No missed edits: detection is relative to a caller-supplied baseline token, so a change between the last read and the wait call is reported immediately.
- One round-trip: on wake, return the change flag plus the full session view.

**Non-Goals:**
- Interrupting a running AI turn (not possible with Claude Code).
- Watching the file on disk (`file-notify`) — we track the live buffer, consistent with the rest of the feature.
- Sub-second precision or a streaming change feed.

## Decisions

### Baseline via a caller-supplied change token
`org_task_session` gains a change token in its output (the buffer's `buffer-chars-modified-tick`). The caller passes the last token to `org_task_wait_for_change`. If the buffer has already moved past it, the tool returns immediately (`changed: true`); otherwise it waits.
- **Why**: stateless (no ambient per-file server state, consistent with path-per-call), and closes the read→wait race — edits made in between are not lost.
- **Alternatives**: snapshot-at-wait-start (misses in-between edits); server tracks last-seen per path (adds ambient state, against the design).

### Event-loop-friendly wait
The wait loops on `(accept-process-output nil poll-interval)` until the tick advances past the baseline or the timeout elapses. This yields control to Emacs so edits, timers, and other requests keep processing.
- **Why**: standard Emacs pattern for "wait but stay alive" in a single-threaded process.
- **Alternatives**: `sleep-for` / busy-loop (freezes the daemon — rejected).

### Change detection = buffer modification tick
Use `buffer-chars-modified-tick` of the file's live buffer as the token/comparison. Any edit (human or tool) advances it.
- **Why**: cheap, monotonic, built-in; no change-hook bookkeeping.
- **Note**: tool-driven mutations also advance the tick; acceptable — the AI compares against its own last-seen token, so it only wakes for changes it hasn't seen.

### Payload on wake = flag + full session view
Return `changed` plus the new token and the same structured view as `org_task_session`.
- **Why**: the AI reacts in one call; no mandatory follow-up read.

### Bounded timeout
The tool takes a timeout (seconds) with a sane default and a hard cap, so a wait can never hang a client or hold the event loop poll indefinitely.

## Risks / Trade-offs

- **File not open in a buffer** → no tick to watch. Mitigation: open it (as the other tools do) before establishing the baseline.
- **Long timeout ties up a client connection** → Mitigation: cap the timeout; the wait yields, so the daemon stays responsive regardless.
- **Tool-driven edits advance the tick** → a wait could wake on the AI's own write. Mitigation: token is caller-supplied and compared to the AI's last-seen value; the AI passes the token from *after* its own writes.
- **Client request timeout shorter than the wait** → the HTTP client may give up first. Mitigation: keep the default well under typical client limits; document.

## Migration Plan

Additive. New helper in `elisp/mcp-emacs.el`, new tool plist, and a token added to `org_task_session` output. Adding a token line to the read output is backward-compatible (extra text). Rollback = remove the tool and the token line.

## Open Questions

- Default and max timeout values (leaning: default 30s, cap 300s).
- Token format in the read output: a labeled line (`Token: <n>`) vs a structured trailer. (Leaning: a labeled line, consistent with the plain-text view.)
