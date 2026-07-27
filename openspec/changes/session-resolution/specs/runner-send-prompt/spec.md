## MODIFIED Requirements

### Requirement: Send input to a live runner session
The system SHALL provide commands that feed input to a runner session
resolved from the live sessions (see the `runner-session-resolution`
capability): sending a prompt string (submitting it), sending an
escape/interrupt, and inserting a newline into the prompt without
submitting. Input SHALL be delivered to the resolved session's terminal.

#### Scenario: Send and submit a prompt
- **WHEN** the user sends a prompt string and a target session resolves
- **THEN** the prompt text is delivered to the resolved session's terminal and submitted

#### Scenario: Send an escape
- **WHEN** the user sends an escape and a target session resolves
- **THEN** an escape/interrupt is delivered to the resolved session's terminal

#### Scenario: Insert a newline without submitting
- **WHEN** the user inserts a newline and a target session resolves
- **THEN** a newline is delivered to the prompt and the prompt is not submitted

### Requirement: Require a live session for input commands
The system SHALL require at least one live runner session when sending
input; these commands SHALL NOT launch a new session. When no live session
exists anywhere, the system SHALL report this rather than starting the CLI.

#### Scenario: No live session
- **WHEN** the user sends input and no live runner session exists anywhere
- **THEN** the system reports that there is no session and does not launch the CLI
