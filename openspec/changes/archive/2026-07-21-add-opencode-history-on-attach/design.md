## Context

`opencode-client--open-buffer` sets up buffer-local state and calls `--start-stream` (live SSE) but never loads prior messages. The renderer reads three buffer-local structures: `--messages` (ordered message ids), `--message-parts` (message id → ordered part ids), and `--parts` (part id → part alist). SSE fills these from standalone `part` events.

History has a different shape (verified against opencode 1.18.0 `/doc`):
- `GET /api/session/{id}/message` → `{data:[SessionMessage], cursor}` (our `--request` already unwraps `data`).
- A user message carries `text` (and files/agents) directly — no separate parts.
- An assistant message carries `content: [ … ]` whose items are `SessionMessageAssistantText | …Reasoning | …Tool`, each with `id`, `type`, and `text` (tool uses `name` instead of the SSE part's `tool` key, and `state` is an enum rather than an object).

## Goals / Non-Goals

**Goals:**
- Seed the existing render model from history and render before streaming.

**Non-Goals:**
- No pagination (first page only; `cursor` ignored, as elsewhere).
- No change to the SSE path or the renderer.
- No new part types beyond what the renderer already handles (text/reasoning/tool).

## Decisions

### Decision: adapt history into the existing SSE render model
Add `opencode-client--seed-history`: fetch the message list, and for each message push its id to `--messages` and populate `--message-parts`/`--parts`:
- user message → synthesize one text part `((id . <mid>:text) (type . "text") (text . <text>))`.
- assistant message → each `content` item becomes a part; normalize by copying `name` → `tool` so `--render-part` (which reads `tool`) works, and coerce `state` to the status string it expects.

Then call `--render`, then `--start-stream`. Because SSE `seq` handling ignores stale events and parts are keyed by id, later live updates for the same ids overwrite cleanly.

- **Alternative:** teach `--render-part` to read both `tool` and `name` and skip the adapter. Rejected — the adapter keeps one render model and localizes the history/stream shape difference in one place.

### Decision: fetch synchronously before streaming
Keep it simple: synchronous history fetch in `--open-buffer` before `--start-stream`, so the transcript is present before any live event. History is bounded (one page) and this path is user-initiated.

## Risks / Trade-offs

- [Part id collision between synthesized user-text ids and real ids] → use a `<mid>:text` suffix unlikely to collide with server part ids (`prt_…`).
- [Large histories block briefly on fetch] → acceptable for a user-initiated open; paginate later if needed.

## Open Questions

- None blocking.
