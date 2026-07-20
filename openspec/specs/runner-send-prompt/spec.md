## Purpose

Drive a live runner session from within Emacs: send a prompt, escape, or
newline to the running CLI terminal, build an at-mention/inline reference
for the current selection, and explain that selection in the session.

## Requirements

### Requirement: Send input to a live runner session
The system SHALL provide commands that feed input to the current project's live runner session: sending a prompt string (submitting it), sending an escape/interrupt, and inserting a newline into the prompt without submitting. Input SHALL be delivered to the session's terminal.

#### Scenario: Send and submit a prompt
- **WHEN** the user sends a prompt string to a project with a live session
- **THEN** the prompt text is delivered to the session's terminal and submitted

#### Scenario: Send an escape
- **WHEN** the user sends an escape to a project with a live session
- **THEN** an escape/interrupt is delivered to the session's terminal

#### Scenario: Insert a newline without submitting
- **WHEN** the user inserts a newline in a project with a live session
- **THEN** a newline is delivered to the prompt and the prompt is not submitted

### Requirement: Require a live session for input commands
The system SHALL require an existing live session for the current project when sending input; these commands SHALL NOT launch a new session. When no live session exists, the system SHALL report this rather than starting the CLI.

#### Scenario: No live session
- **WHEN** the user sends input for a project that has no live session
- **THEN** the system reports that there is no session and does not launch the CLI

### Requirement: Build a reference for the current selection
The system SHALL build a textual reference for the current selection to embed in a prompt. For a buffer visiting a file, the reference SHALL be an at-mention of the file path relative to the project root with the line span of the active region (or the single line at point when no region is active). For a buffer not visiting a file, the reference SHALL be the selected text verbatim (or the current line when no region is active).

#### Scenario: File-backed buffer with a region
- **WHEN** a reference is built in a file-backed buffer with an active region spanning lines 12 to 20
- **THEN** the reference is an at-mention of the project-relative path with the span `12-20`

#### Scenario: File-backed buffer without a region
- **WHEN** a reference is built in a file-backed buffer with no active region, point on line 12
- **THEN** the reference is an at-mention of the project-relative path with the single line `12`

#### Scenario: Non-file buffer
- **WHEN** a reference is built in a buffer that does not visit a file
- **THEN** the reference is the selected text (or the current line when no region is active)

### Requirement: Explain the current selection in the session
The system SHALL provide a command that builds a reference for the current selection and sends an explain request for it to the current project's live session.

#### Scenario: Explain a selection
- **WHEN** the user invokes explain-selection with a region active in a project with a live session
- **THEN** an explain request referencing the selection is sent to and submitted in the session

#### Scenario: Explain with no live session
- **WHEN** the user invokes explain-selection for a project with no live session
- **THEN** the system reports that there is no session and does not launch the CLI
