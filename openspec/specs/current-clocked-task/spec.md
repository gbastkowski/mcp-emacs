## Purpose

Define the read-only MCP capability for retrieving the Org task currently clocked in from Emacs.

## Requirements

### Requirement: Current clocked task is exposed as a read-only MCP tool
The system SHALL expose the current Org clock state through a read-only MCP tool for retrieving the currently clocked in task.
The capability MUST be exposed as a tool rather than a resource or a mutating operation.

#### Scenario: Tool is available for current clock lookup
- **WHEN** an MCP client inspects the server's available tools
- **THEN** the server includes a tool for retrieving the currently clocked in Org task

### Requirement: Active Org clock returns the current task text
When an Org task is currently clocked in, the tool SHALL return the heading text of that task as plain user-facing text.
The response MUST represent the current global Org clock state rather than the current buffer selection or point.

#### Scenario: Clocked task is active
- **WHEN** an Org task is currently clocked in in Emacs
- **THEN** the tool returns the heading text of the currently clocked in task

### Requirement: Missing clock returns friendly fallback text
When no Org task is currently clocked in, the tool SHALL return a stable friendly fallback message.
The tool MUST NOT surface raw `nil` or treat the absence of an active clock as an error.

#### Scenario: No task is currently clocked in
- **WHEN** no Org task is currently clocked in in Emacs
- **THEN** the tool returns a friendly plain-text message indicating that no task is currently clocked in

### Requirement: Response scope stays intentionally narrow
The tool SHALL return only the current task text or the defined fallback message.
The capability MUST NOT include additional structured metadata such as file path, tags, timestamps, or elapsed clock duration.

#### Scenario: Client requests current clocked task
- **WHEN** the tool is invoked
- **THEN** the response contains only plain text for the current task or the fallback message
