## MODIFIED Requirements

### Requirement: Manage the runner window
The system SHALL provide commands to show, hide, and toggle the runner window, placing the buffer in an ordinary (non-dedicated) window in a configurable direction, with control over whether focus moves to the runner.

#### Scenario: Toggling visibility
- **WHEN** the user toggles the runner window while it is visible
- **THEN** the window is hidden, and toggling again shows it

#### Scenario: Directional placement
- **WHEN** the runner window is shown
- **THEN** it appears in an ordinary window placed in the configured direction (default to the right), so it can be split, navigated, and closed like any other window rather than a dedicated side window
