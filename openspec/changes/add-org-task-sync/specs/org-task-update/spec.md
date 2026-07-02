## ADDED Requirements

### Requirement: Updates are performed through the live Emacs buffer
The mutating MCP tools SHALL modify the target Org task file through its live Emacs buffer (opening it if necessary) and MUST NOT write the file directly on disk behind Emacs.
Mutations MUST be scoped to specific subtrees or items rather than rewriting the whole buffer.

#### Scenario: Mutation on an open buffer with unsaved edits
- **WHEN** the target file has unsaved human edits in its buffer
- **AND** an MCP client performs an update
- **THEN** the update is applied to the live buffer, preserving the concurrent human edits

#### Scenario: Mutation on a file not yet open
- **WHEN** the target file is not currently open in a buffer
- **THEN** the tool opens it in Emacs and applies the update through that buffer

### Requirement: Session status can be updated
The system SHALL expose a tool to set the session status of the task file, using the Org TODO keyword machinery configured in the environment.

#### Scenario: Setting a valid session status
- **WHEN** an MCP client sets the session status to a configured Org keyword
- **THEN** the task file's session status reflects the new keyword

#### Scenario: Setting an unrecognized status
- **WHEN** an MCP client requests a status that is not a configured Org keyword
- **THEN** the tool returns a friendly plain-text message and leaves the status unchanged

### Requirement: A known TODO item's status can be updated
The system SHALL expose a tool to set the Org keyword of an individual TODO item that the tool can identify (by item id property when present, otherwise by heading text).
The tool MUST use Org keywords rather than a separate status vocabulary.

#### Scenario: Updating an identifiable item
- **WHEN** an MCP client sets the status of a TODO item that can be identified
- **THEN** that item's Org keyword is updated and no other item is changed

#### Scenario: Item cannot be identified
- **WHEN** the referenced TODO item cannot be identified in the file
- **THEN** the tool returns a friendly plain-text message and makes no edit

### Requirement: Progress notes and new items can be appended without clobbering human content
The system SHALL expose a tool to append a progress note and/or a new TODO item under the task heading at a defined insertion point.
The tools MUST NOT reorder, delete, or rewrite human-authored items they did not create.

#### Scenario: Appending a progress note
- **WHEN** an MCP client appends a progress note
- **THEN** the note is added at the defined insertion point and existing human content is unchanged

#### Scenario: Appending a new TODO item
- **WHEN** an MCP client appends a new TODO item
- **THEN** the item is added under the task heading and existing items keep their order and content

#### Scenario: Attempt to delete or reorder human items
- **WHEN** an update would reorder, delete, or rewrite a human-authored item the AI did not create
- **THEN** the tool does not perform that operation

### Requirement: Mutations do not force a save unless defined
Mutating tools SHALL apply edits to the buffer and MUST NOT save the buffer to disk unless a tool is explicitly defined to save.
Save decisions are otherwise left to the human or the existing save tool.

#### Scenario: Update applied without save
- **WHEN** an MCP client performs an update through a tool not defined to save
- **THEN** the buffer reflects the change and the file is not saved to disk by that tool
