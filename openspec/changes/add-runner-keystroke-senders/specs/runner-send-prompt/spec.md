## ADDED Requirements

### Requirement: Send a single keystroke to a live runner session
The system SHALL provide commands that each feed a single keystroke to the current project's live runner session: a carriage return, the digits `1`, `2`, and `3` (for numbered menus), a shift-tab (to cycle mode), and the up and down arrow keys. Each command SHALL deliver the corresponding input to the session's terminal and SHALL require an existing live session, never launching a new one.

#### Scenario: Send a carriage return
- **WHEN** the user invokes the send-return command in a project with a live session
- **THEN** a carriage return is delivered to the session's terminal

#### Scenario: Send a numbered menu choice
- **WHEN** the user invokes a send-digit command (1, 2, or 3) in a project with a live session
- **THEN** the corresponding digit is delivered to the session's terminal

#### Scenario: Send shift-tab to cycle mode
- **WHEN** the user invokes the send-shift-tab command in a project with a live session
- **THEN** the shift-tab escape sequence is delivered to the session's terminal

#### Scenario: Send an arrow key
- **WHEN** the user invokes the send-up or send-down command in a project with a live session
- **THEN** the corresponding arrow-key escape sequence is delivered to the session's terminal

#### Scenario: Keystroke command with no live session
- **WHEN** the user invokes any single-keystroke command for a project with no live session
- **THEN** the system reports that there is no session and does not launch the CLI
