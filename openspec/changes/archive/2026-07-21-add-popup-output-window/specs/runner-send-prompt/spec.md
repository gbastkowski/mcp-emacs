## MODIFIED Requirements

### Requirement: Explain the current selection in the session
The system SHALL provide a command that builds a reference for the current selection and produces an explanation for it. The command SHALL choose its output sink based on session-buffer visibility: when a window is showing the current project's session buffer, the explanation SHALL be sent to and submitted in that live session; when no window is showing the session buffer, the explanation SHALL be rendered in the popup output window instead.

#### Scenario: Explain with the session buffer visible
- **WHEN** the user invokes explain-selection with a region active in a project whose session buffer is visible in a window
- **THEN** an explain request referencing the selection is sent to and submitted in the session

#### Scenario: Explain with the session buffer not visible
- **WHEN** the user invokes explain-selection with a region active in a project that has a live session whose buffer is not visible in any window
- **THEN** the explanation is rendered in the popup output window rather than sent to the session terminal

#### Scenario: Explain with no live session
- **WHEN** the user invokes explain-selection for a project with no live session
- **THEN** the system reports that there is no session and does not launch the CLI
