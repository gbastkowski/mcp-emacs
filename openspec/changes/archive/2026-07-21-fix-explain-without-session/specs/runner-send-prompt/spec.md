## MODIFIED Requirements

### Requirement: Explain the current selection in the session
The system SHALL provide a command that builds a reference for the current selection and produces an explanation for it. The command SHALL choose its output sink based on session-buffer visibility: when a window is showing the current project's session buffer, the explanation SHALL be sent to and submitted in that live session; otherwise — whether the project has a hidden session or no session at all — the explanation SHALL be fetched with a one-shot headless query and rendered in the popup output window. The command SHALL NOT require a live session and SHALL NOT launch a TUI session.

#### Scenario: Explain with the session buffer visible
- **WHEN** the user invokes explain-selection with a region active in a project whose session buffer is visible in a window
- **THEN** an explain request referencing the selection is sent to and submitted in the session

#### Scenario: Explain with a hidden session
- **WHEN** the user invokes explain-selection in a project that has a live session whose buffer is not visible in any window
- **THEN** the explanation is fetched with a headless query and rendered in the popup output window

#### Scenario: Explain with no session
- **WHEN** the user invokes explain-selection in a project that has no live session
- **THEN** the explanation is fetched with a headless query and rendered in the popup output window, and no TUI session is launched
