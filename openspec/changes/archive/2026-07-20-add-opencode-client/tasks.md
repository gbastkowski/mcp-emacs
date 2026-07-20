## 1. Scaffolding and connection

- [x] 1.1 Create `elisp/opencode-client.el` with header, `(require 'plz nil t)` soft dep, `(require 'json)`, and a `mcp-emacs`/`opencode-client` customization group
- [x] 1.2 Add defcustoms: opencode executable, host (default 127.0.0.1), port (default 4096), optional password
- [x] 1.3 Implement a request helper that issues HTTP calls via plz with optional basic auth, erroring clearly when plz is absent
- [x] 1.4 Implement `opencode-client-health` against `GET /api/health` and a connect/attach entry point that verifies the server before use
- [x] 1.5 Implement optional `opencode-client-serve` that spawns `opencode serve` and waits for health (attach-to-existing remains the primary path, per design D7)

## 2. Session management

- [x] 2.1 Implement list (`GET /api/session`), create (`POST /api/session`), and delete (`DELETE /api/session/{id}`) session calls
- [x] 2.2 Track the active session; implement select/switch and clear-active-on-delete
- [x] 2.3 Provide interactive commands to create, switch (with `completing-read`), and delete sessions

## 3. Conversation model and rendering

- [x] 3.1 Implement per-session state: ordered messages and a per-message table of parts keyed by `part.id`, tracking the highest `seq` seen (design D1)
- [x] 3.2 Implement `apply-sync-event`: upsert on `message.part.updated.1`, remove on part removed, upsert message metadata on `message.updated.1`, ignore stale/duplicate `seq` and unknown event types
- [x] 3.3 Implement the chat buffer (major mode from `special-mode`, name `*opencode:<title>*`) and per-message region rendering: text parts as prose, reasoning folded, tool parts as a compact `tool: state` line (design D2)
- [x] 3.4 Keep point/scroll stable with follow-tail behavior when point is at end

## 4. Streaming

- [x] 4.1 Open the per-session SSE stream (`GET /api/session/{id}/event`) with plz `:as (stream ...)` and a process filter (design D3)
- [x] 4.2 Implement SSE framing in the filter: accumulate bytes, split on `\n\n`, parse each `data:` payload as JSON, keep a partial-line buffer across chunks
- [x] 4.3 Dispatch parsed events to `apply-sync-event` and re-render the affected message
- [x] 4.4 Cancel/close the stream on session switch, buffer kill, and disconnect; report disconnects rather than hanging

## 5. Prompting and interaction

- [x] 5.1 Implement send-prompt (`POST /api/session/{id}/prompt`) with `delivery` steer/queue; do not block on the response body (reply arrives via SSE, design D4)
- [x] 5.2 Implement interrupt (`POST /api/session/{id}/interrupt`)
- [x] 5.3 Implement permission handling: detect pending permission, prompt the user, POST the decision to the reply endpoint without blocking the SSE filter (design D5)
- [x] 5.4 Implement question handling: detect a question, prompt the user, POST the reply or rejection
- [x] 5.5 Provide the input affordance in the chat buffer (a command to compose and send a prompt to the active session)

## 6. Verification and docs

- [x] 6.1 Byte-compile `elisp/opencode-client.el` clean (no unconditional plz require; soft-dep guard verified)
- [x] 6.2 SSE framing unit check: feed synthetic multi-chunk `data:` frames (including a frame split across two chunks) to the filter and assert correct event parsing and part upsert — no live server needed
- [ ] 6.3 Live smoke test against a running `opencode serve` with a configured provider: connect, create session, send a prompt, observe streamed rendering, exercise a permission/question reply (requires a configured LLM provider; may be done manually)
- [x] 6.4 Update `README.md` with an opencode-client section (start/attach, key commands, plz requirement)
