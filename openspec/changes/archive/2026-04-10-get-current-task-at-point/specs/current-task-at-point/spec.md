## ADDED Requirements

### Requirement: Current TODO task at point is exposed as a read-only MCP tool
The system SHALL expose the Org TODO task at the current point through a read-only MCP tool.
The capability MUST be exposed as a tool rather than a resource or a mutating operation.

#### Scenario: Tool is available for point-scoped task lookup
- **WHEN** an MCP client inspects the server's available tools
- **THEN** the server includes a tool for retrieving the current Org TODO task at point

### Requirement: Valid Org TODO task context returns the task text
When point is on or within a valid Org TODO task context, the tool SHALL return the heading text of the enclosing task as plain user-facing text.
The response MUST be based on the current point in the active buffer rather than global Org clock state.

#### Scenario: Point is on an Org TODO task heading
- **WHEN** point is on an Org TODO task heading in Emacs
- **THEN** the tool returns the heading text of that task

#### Scenario: Point is within an Org TODO task subtree
- **WHEN** point is within the subtree of an Org TODO task in Emacs
- **THEN** the tool returns the heading text of the enclosing task

### Requirement: Invalid task context returns friendly fallback text
When point is not on or within a valid Org TODO task context, the tool SHALL return a stable friendly fallback message.
The tool MUST NOT surface raw `nil` or treat the absence of a valid TODO task at point as an error.

#### Scenario: Point is outside an Org TODO task
- **WHEN** point is outside any valid Org TODO task context in Emacs
- **THEN** the tool returns a friendly plain-text message indicating that there is no current task at point

### Requirement: Response scope stays intentionally narrow
The tool SHALL return only the task heading text or the defined fallback message.
The capability MUST NOT include additional structured metadata such as file path, tags, TODO state objects, outline path, or marker position.

#### Scenario: Client requests current task at point
- **WHEN** the tool is invoked
- **THEN** the response contains only plain text for the task at point or the fallback message
