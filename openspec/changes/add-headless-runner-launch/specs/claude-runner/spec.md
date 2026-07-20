## ADDED Requirements

### Requirement: Start a session without displaying its window
The system SHALL provide a command to start a project's runner session headless: the CLI runs in its eat buffer and is registered as the project's primary session, but no window is displayed and focus does not move to it. The headless buffer SHALL be revealable afterwards through the existing show/toggle/switch commands, and SHALL participate in the one-session-per-project reuse model.

#### Scenario: Starting headless
- **WHEN** the user starts the runner headless from a buffer inside a project that has no live session
- **THEN** the CLI starts in an eat buffer registered as that project's session, and no window for it is displayed

#### Scenario: Revealing a headless session
- **WHEN** the user toggles or switches to a session that was started headless
- **THEN** the session's buffer is displayed in the runner window

#### Scenario: Starting headless when a session already exists
- **WHEN** the user starts the runner headless for a project that already has a live session
- **THEN** the existing session is reused and no duplicate is started, and no window is displayed
