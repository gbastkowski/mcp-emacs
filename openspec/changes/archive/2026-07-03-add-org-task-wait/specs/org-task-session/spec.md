## MODIFIED Requirements

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
