## Context

opencode `serve` exposes a documented HTTP API (`/api/*`) and a Server-Sent
Events stream. Probing the live OpenAPI spec (v1.18.0) fixed the data model this
design depends on:

- **Event envelope** (SSE): `{ type: "sync", id: "evt_…",
  syncEvent: { type: "message.part.updated.1" | "message.updated.1" | …,
  seq: <number>, aggregateID, data: { sessionID, part | info } } }`.
- **`Part`** is a discriminated union on a `type` field —
  `TextPart`, `ReasoningPart`, `ToolPart`, `StepStartPart`, `StepFinishPart`,
  `FilePart`, `PatchPart`, `SubtaskPart`, `AgentPart`, … — and **every variant
  carries `id`, `messageID`, `sessionID`**. `TextPart` has `text`; `ToolPart`
  has `tool` + `state`; `ReasoningPart` has `text`.
- **Ordering**: each sync event has a monotonic `seq`.

Emacs is single-threaded; the SSE stream must be consumed without blocking the
UI. `plz` (curl-based) supports streaming responses via `:as '(stream …)`,
delivering chunks to a process filter.

## Goals / Non-Goals

**Goals:**
- A native chat UI in an Emacs buffer, driven by the opencode HTTP API + SSE.
- Correct incremental rendering from `message.part.updated` events.
- Handle permission and question interactions.
- No hard dependency: `plz` used only when present.

**Non-Goals:**
- Any backend abstraction over Claude/opencode (explicitly deferred — the API's
  richness would be lost to a lowest-common-denominator protocol).
- Reimplementing editor tools (opencode gets those from `mcp-emacs` over MCP via
  `opencode.json`).
- Running the opencode TUI in a terminal.

## Decisions

### D1: Model the conversation as parts keyed by id, grouped by message, ordered by seq
Maintain per-session state: an ordered list of messages, and within each a table
of parts keyed by `part.id`. Each `message.part.updated.1` event is an **upsert**
by `part.id`; `message.part.removed` deletes; `message.updated.1` upserts message
metadata. Track the highest `seq` seen to ignore out-of-order/duplicate events.
This mirrors how the parts stream (a `TextPart` grows its `text` across repeated
updates of the same `id`).

- **Alternative considered:** append-only rendering of each event. Rejected —
  parts are *updated in place* (streaming text reuses one part id), so append
  would duplicate text.

### D2: Render into a dedicated chat buffer, re-rendering changed regions
Each session has a buffer (name like `*opencode:<session-title>*`) in a major
mode derived from `special-mode`. On each applied event, re-render the affected
message's region from the part table (text parts as prose, reasoning folded,
tool parts as a compact `tool: state` line). Keep point/scroll stable unless the
user is at the end (follow-tail behavior). Use markers or text-property regions
per message so a single part update doesn't redraw the whole buffer.

### D3: Consume SSE with plz streaming into a process filter
Open `GET /api/session/{id}/event` with `plz` `:as '(stream …)`. A filter
accumulates bytes, splits on SSE framing (`\n\n`), parses each `data:` payload as
JSON, and dispatches by `syncEvent.type`. Keep a partial-line buffer for chunks
split mid-frame. Close/cancel the stream on session switch, buffer kill, or
disconnect; surface disconnects rather than hanging.

- **Alternative considered:** `url.el` with a manual process filter. Rejected for
  now — `plz` gives SSE framing and curl robustness; it is a soft dependency
  (D6).

### D4: Prompt and interrupt map directly to endpoints
`POST /api/session/{id}/prompt` with `{ prompt, delivery }` where `delivery` is
`steer` (mid-turn) or `queue`; `POST /api/session/{id}/interrupt` to stop.
Sending does not wait for the response body — the reply arrives over the SSE
stream (D3), so the UI stays responsive.

### D5: Permission and question requests are handled off the event stream
When the stream signals a pending permission or question (or via the
`/permission` and `/question` endpoints), prompt the user in Emacs
(`y-or-n-p` / `completing-read` / minibuffer) and POST the reply to the
corresponding reply/reject endpoint for the request id. Never block the SSE
filter itself on user input — schedule the prompt so the stream keeps draining.

### D6: plz is a soft dependency
`(require 'plz nil t)`. Loading the client file never hard-requires plz;
client commands check for it and error with a clear "install plz" message if
absent. Keeps `mcp-emacs` installable without plz, consistent with the eat and
projectile patterns already used in this repo.

### D7: Server lifecycle — attach first, optionally start
The client connects to a configured host/port and health-checks
(`GET /api/health`). Starting a local `opencode serve` is a convenience command
(spawn the process, wait for health), but attach-to-existing is the primary
path so the client works against a server the user already runs.

## Risks / Trade-offs

- **Event schema drift across opencode versions** (event `type` strings carry a
  `.1` version suffix) → dispatch on the known suffixes and ignore unknown event
  types rather than erroring, so a newer server degrades gracefully.
- **SSE frame splitting across chunks** → the filter keeps a partial buffer and
  only parses complete `\n\n`-terminated frames (D3).
- **Large conversations re-rendered often** → per-message region rendering (D2)
  and seq-gated updates (D1) bound the work per event.
- **plz absence** → soft dependency with a clear error (D6); does not break
  loading `mcp-emacs`.
- **Auth**: password sent as HTTP basic on every request; rely on loopback
  binding and let the user supply the password via a variable or auth-source.

## Open Questions

- Should the chat buffer support sending edits/attachments (FilePart) in the
  first version, or text-only prompts? Plan: text-only first; PromptInput
  supports richer content, add later.
- Reuse the global `/api/event` stream (one connection, filter by sessionID) vs.
  a per-session `/api/session/{id}/event` stream. Plan: per-session for
  simplicity now; switch to one global stream if managing many sessions.
