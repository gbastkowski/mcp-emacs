## Purpose

Define the read-only MCP capability for reading an Org task session file by explicit path, reflecting live Emacs buffer state, and returning structured, readable session contents derived from the file itself.

## Requirements

### Requirement: Session task file is read through explicit path
The system SHALL expose read-only MCP tools that accept the target Org task file path (or a session id resolving to a path) as an explicit argument.
The server MUST NOT hold ambient "current task file" state; each read is scoped to the path given in the call.

#### Scenario: Reading a session task file by path
- **WHEN** an MCP client invokes a session read tool with a valid Org task file path
- **THEN** the tool reads that file and returns its session contents

#### Scenario: Missing or invalid path
- **WHEN** the path does not resolve to a readable Org file
- **THEN** the tool returns a friendly plain-text message and does not raise a raw error

### Requirement: Reads reflect live buffer state
When the target Org file is open in an Emacs buffer, the read tools SHALL reflect the current buffer contents, including unsaved human edits, rather than the last-saved disk contents.

#### Scenario: File open with unsaved human edits
- **WHEN** a human has unsaved edits in the buffer for the target Org file
- **AND** an MCP client reads the session
- **THEN** the returned contents include the unsaved edits

### Requirement: Session contents are returned as structured, readable text
The read tools SHALL return the task heading, the assigned session id, the session status, the TODO checklist with each item's Org keyword, and a change token identifying the current state of the file.
The output MUST be plain text that is both human-glanceable and parseable by a harness.
The change token MUST advance whenever the file's buffer is edited, so a caller can pass it to a wait tool to detect subsequent changes.

#### Scenario: Fetching the full session view
- **WHEN** an MCP client reads a populated session task file
- **THEN** the response includes the task heading, session id, session status, each TODO item with its current Org keyword, and a change token

#### Scenario: Empty TODO checklist
- **WHEN** the task file has a task heading but no TODO items
- **THEN** the response includes the task heading, session metadata, a change token, and indicates an empty checklist

#### Scenario: Token advances after an edit
- **WHEN** an MCP client reads the session, the file's buffer is then edited, and the client reads again
- **THEN** the change token in the second response differs from the first

### Requirement: Session id and status are derived from the Org file
The session id and session status SHALL be stored in and derived from the Org task file itself (heading, properties, or keyword) rather than from server-side state.

#### Scenario: Session metadata present
- **WHEN** the Org task file records a session id and a status
- **THEN** the read tool returns those values as stored in the file

#### Scenario: Session metadata absent
- **WHEN** the Org task file has no recorded session id or status
- **THEN** the tool returns a defined fallback indication rather than a raw nil
