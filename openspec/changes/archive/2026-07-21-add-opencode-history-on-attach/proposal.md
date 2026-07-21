## Why

Sessions live on the opencode server and survive Emacs restarts, so the intended workflow is to run `opencode serve` separately and reconnect from Emacs. But opening an existing session only starts the live SSE stream — it never loads prior messages, so the chat buffer is blank until the next turn. That defeats the point of persistent sessions.

## What Changes

- When opening a chat buffer for a session, fetch the session's message history (`GET /api/session/{id}/message`), seed the conversation model from it, render, and only then start the live stream — so reconnecting shows the existing conversation.
- Map history messages into the same in-buffer model the SSE renderer uses:
  - user messages contribute their `text` as a text part;
  - assistant messages contribute their `content` items (text / reasoning / tool), normalizing the tool part's `name` field to the `tool` key the renderer reads.

## Capabilities

### New Capabilities

### Modified Capabilities
- `opencode-client`: opening a session loads and renders prior history before streaming live events.

## Impact

- `elisp/opencode-client.el` — history fetch + seeding in the open-buffer path; a small history-part adapter.
- Tests: seeding the model from a canned history payload renders the expected transcript.
- No MCP tool surface change. Pagination `cursor` still ignored (first page only for now).
