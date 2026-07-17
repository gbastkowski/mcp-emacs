## ADDED Requirements

### Requirement: Interactive diff/apply tool presents a proposal via ediff
The system SHALL expose an MCP tool that accepts a file path and proposed new content, opens an `ediff` session comparing the file's current content against the proposal, and lets the human review, edit, accept, or reject the proposal interactively before the tool returns.

#### Scenario: Accepting the proposal as-is
- **WHEN** a client calls the diff tool with a path and new content and the human accepts the proposal
- **THEN** the tool writes the accepted content to the buffer and returns a status of `applied` together with the final content

#### Scenario: Rejecting the proposal
- **WHEN** the human rejects the proposal during the ediff session
- **THEN** the tool leaves the file's buffer unchanged and returns a status of `rejected`

#### Scenario: Human edits the proposal before accepting
- **WHEN** the human edits the proposed side during the ediff session and then accepts
- **THEN** the tool returns a status of `applied` with the human-edited content, not the original proposal

### Requirement: Diff/apply waiting does not block the Emacs event loop
While waiting for the human's decision, the diff tool SHALL yield to the Emacs event loop so that human edits, timers, and other MCP tool calls continue to be processed.

#### Scenario: Other work proceeds during a diff wait
- **WHEN** the diff tool is waiting for the human to resolve the ediff session
- **THEN** other MCP tool calls and buffer edits continue to be handled

### Requirement: Diff/apply wait is bounded by a timeout
The diff tool SHALL apply a default timeout when none is given and MUST cap the timeout at a defined maximum, so the call cannot hang indefinitely.

#### Scenario: Human does not respond in time
- **WHEN** the human neither accepts nor rejects before the timeout elapses
- **THEN** the tool abandons the ediff session, leaves the buffer unchanged, and returns a status of `timeout`

#### Scenario: Excessive timeout requested
- **WHEN** a client requests a timeout above the maximum
- **THEN** the tool waits no longer than the maximum

### Requirement: Open editors can be listed
The system SHALL expose an MCP tool that returns the live file-visiting buffers, each with its file path, buffer name, and modified (dirty) flag.

#### Scenario: Listing visited files
- **WHEN** a client calls the open-editors tool while files are open in Emacs
- **THEN** the tool returns an entry for each file-visiting buffer with its path, buffer name, and whether it has unsaved changes

#### Scenario: No files open
- **WHEN** a client calls the open-editors tool and no file-visiting buffers exist
- **THEN** the tool returns an empty list rather than raising an error

### Requirement: Document dirty state can be queried
The system SHALL expose an MCP tool that reports whether a given file's buffer has unsaved changes.

#### Scenario: File has unsaved changes
- **WHEN** a client queries the dirty state of a file whose buffer has been modified since its last save
- **THEN** the tool reports that the document is dirty

#### Scenario: File is not open
- **WHEN** a client queries the dirty state of a file that has no live buffer
- **THEN** the tool reports that the document is not dirty (or not open) rather than raising an error
