## ADDED Requirements

### Requirement: Claude window opens at a configurable width

The system SHALL display the Claude Code buffer in a window whose width is
controlled by a user-configurable variable, defaulting to 120 columns.

#### Scenario: Default width

- **WHEN** the Claude Code buffer is displayed and the user has not
  customized the width variable
- **THEN** the window is sized to 120 columns wide

#### Scenario: Customized width

- **WHEN** the user sets the width variable to N columns and the Claude
  Code buffer is displayed
- **THEN** the window is sized to N columns wide (subject to the frame
  fraction clamp)

### Requirement: Width is clamped to a maximum frame fraction

The system SHALL clamp the Claude window width so it never exceeds a
user-configurable maximum fraction of the frame's total width, ensuring
the code pane is not crushed on narrow frames.

#### Scenario: Configured width fits within the clamp

- **WHEN** the configured width in columns is at or below the max-fraction
  of the current frame width
- **THEN** the window uses the configured width

#### Scenario: Configured width exceeds the clamp on a narrow frame

- **WHEN** the configured width in columns exceeds the max-fraction of the
  current frame width
- **THEN** the window width is reduced to the max-fraction of the frame
  width

### Requirement: Claude window is a normal splittable window

The system SHALL display the Claude Code buffer in an ordinary Emacs
window (not an Emacs side window), so the window can be split, moved, and
managed with standard window commands.

#### Scenario: Window can be split

- **WHEN** the Claude window is displayed and the user issues a standard
  window-split command on it
- **THEN** the split succeeds (the window is not a side window that
  refuses splitting)

### Requirement: Claude window is weakly dedicated to its buffer

The system SHALL mark the Claude window as weakly dedicated to the Claude
Code buffer, so the window prefers to keep showing that buffer but
`display-buffer` MAY still reuse it when no better window is available.

#### Scenario: Ordinary buffer display avoids the Claude window

- **WHEN** the Claude window is showing the Claude Code buffer and the
  user opens another buffer (e.g. via find-file) while another suitable
  window exists
- **THEN** the other buffer is displayed in a different window, leaving
  the Claude buffer visible

#### Scenario: display-buffer may override when necessary

- **WHEN** the Claude window is the only candidate window available to
  `display-buffer`
- **THEN** `display-buffer` MAY reuse the Claude window (weak, not strong,
  dedication)
