## ADDED Requirements

### Requirement: Client loads session history when opening a session
When the client opens a chat buffer for a session, it SHALL fetch the session's existing message history from the server, seed the conversation model from it, and render it before subscribing to the live event stream, so reconnecting to a persistent session shows the prior conversation rather than an empty buffer.

#### Scenario: Reattach shows prior conversation
- **WHEN** the client opens a session that already has messages on the server
- **THEN** the existing messages are rendered into the chat buffer before any new live events arrive

#### Scenario: New session has no history
- **WHEN** the client opens a freshly created session with no messages
- **THEN** the buffer renders empty and streaming proceeds normally

#### Scenario: History parts map to the render model
- **WHEN** history contains a user message with text and an assistant message with text, reasoning, and tool content parts
- **THEN** each part is rendered the same way the equivalent live streamed part would be
