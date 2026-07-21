## Purpose

Define a native Emacs client for opencode's local HTTP API: connect to a
headless `opencode serve`, manage sessions, send prompts (with steer/queue and
interrupt), render the conversation incrementally from the server's Server-Sent
Events stream into an Emacs buffer, and handle opencode's permission and
question interactions — all over plain HTTP/SSE, with editor tools provided to
opencode through the mcp-emacs MCP server.

## Requirements

### Requirement: Client connects to a running opencode server
The system SHALL connect to an `opencode serve` HTTP endpoint at a configurable host and port, verify it with a health check, and support an optional server password for HTTP basic auth.

#### Scenario: Healthy server
- **WHEN** the client connects to a reachable opencode server
- **THEN** the health check succeeds and the client is ready to issue requests

#### Scenario: Server not reachable
- **WHEN** the client cannot reach the configured host/port
- **THEN** the client reports a clear connection error rather than failing opaquely

#### Scenario: Password-protected server
- **WHEN** the server requires a password and one is configured
- **THEN** the client authenticates with HTTP basic auth on every request

### Requirement: Client manages opencode sessions
The system SHALL list, create, select, and delete opencode sessions through the server API, and track which session is currently active.

#### Scenario: Listing sessions
- **WHEN** the user lists sessions
- **THEN** the client returns the server's sessions with enough detail to choose one

#### Scenario: Creating and selecting a session
- **WHEN** the user creates a new session
- **THEN** the client creates it on the server and makes it the active session

#### Scenario: Deleting a session
- **WHEN** the user deletes a session
- **THEN** the client removes it on the server and, if it was active, clears the active session

### Requirement: Client sends prompts and can interrupt
The system SHALL send a user prompt to the active session with a selectable delivery mode (steer or queue) and SHALL be able to interrupt a running session.

#### Scenario: Sending a prompt
- **WHEN** the user submits a prompt to the active session
- **THEN** the client posts it to the server and the response begins streaming into the chat buffer

#### Scenario: Steering a running turn
- **WHEN** the user submits a prompt with steer delivery while a turn is in progress
- **THEN** the client delivers it as a steering message rather than queuing it

#### Scenario: Interrupting
- **WHEN** the user interrupts the active session
- **THEN** the client asks the server to stop the running turn

### Requirement: Client renders the conversation incrementally from the event stream
The system SHALL subscribe to the session's Server-Sent Events stream and render the conversation incrementally into an Emacs buffer, applying message and message-part events (message updated, part updated/removed, and text/reasoning/tool/step lifecycle events) as they arrive.

#### Scenario: Streaming assistant text
- **WHEN** the server emits message-part update events for assistant text
- **THEN** the chat buffer updates incrementally as the parts arrive, without waiting for the full turn

#### Scenario: Tool and reasoning activity
- **WHEN** the server emits tool-input or reasoning lifecycle events
- **THEN** the client reflects that activity in the buffer so the user can see what the agent is doing

#### Scenario: Stream interrupted or server gone
- **WHEN** the event stream ends unexpectedly or the server disconnects
- **THEN** the client stops rendering cleanly and reports the disconnection rather than hanging

### Requirement: Client surfaces and answers permission and question requests
The system SHALL detect opencode permission requests and questions for the active session and let the user answer them from Emacs, sending the reply back to the server.

#### Scenario: Permission request
- **WHEN** the server requests permission (for example to run a tool) during a turn
- **THEN** the client presents the request to the user and sends the user's decision back to the server

#### Scenario: Question request
- **WHEN** the server asks the user a question during a turn
- **THEN** the client presents the question and sends the user's reply (or rejection) back to the server

### Requirement: The client adds no hard package dependency
The client SHALL use `plz` for HTTP and SSE only when it is available, loaded as a soft/optional dependency, so installing `mcp-emacs` does not require `plz`.

#### Scenario: plz available
- **WHEN** `plz` is loaded
- **THEN** the client uses it for HTTP requests and the SSE stream

#### Scenario: plz not available
- **WHEN** `plz` is not loaded
- **THEN** loading `mcp-emacs` still succeeds and the client reports that it needs `plz` only when a client command is invoked

### Requirement: Client unwraps the server response envelope
The opencode server returns most responses wrapped in a `data` envelope (and list responses alongside a `cursor`). The client SHALL unwrap this envelope before use: when a parsed JSON response is a map carrying a `data` key, the client SHALL use the value of `data`; otherwise it SHALL use the parsed response unchanged, so flat responses (such as the health check) continue to work.

#### Scenario: Wrapped object response
- **WHEN** the server returns a wrapped object such as a created session `{"data": {"id": …}}`
- **THEN** the client uses the inner object, so fields like the session id are read correctly

#### Scenario: Wrapped list response
- **WHEN** the server returns a wrapped list such as `{"data": [ … ], "cursor": …}`
- **THEN** the client uses the inner list as the collection

#### Scenario: Flat response
- **WHEN** the server returns a flat object with no `data` key, such as the health check `{"healthy": true}`
- **THEN** the client uses the response unchanged
