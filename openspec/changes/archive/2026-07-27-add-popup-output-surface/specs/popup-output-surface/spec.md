## ADDED Requirements

### Requirement: Render markdown content in a popup output surface
The system SHALL provide a command that takes markdown content and a kind identifier and renders the content in a dedicated buffer shown in a regular split window. The buffer SHALL be rendered read-only with markdown formatting and native syntax highlighting for fenced code blocks. The window SHALL NOT auto-hide; it SHALL persist until the user dismisses it.

#### Scenario: Render markdown content
- **WHEN** the command is invoked with markdown content and a kind identifier
- **THEN** the content is rendered read-only in a dedicated buffer with markdown formatting and fenced code blocks syntax-highlighted, and the buffer is shown in a regular split window

#### Scenario: Fenced code blocks are highlighted
- **WHEN** the content contains a fenced code block with a language tag
- **THEN** the code inside the block is fontified for that language

#### Scenario: Surface persists
- **WHEN** the popup is shown and the user runs other commands that do not dismiss it
- **THEN** the popup window remains visible

### Requirement: Support scroll, select, and copy in the surface
The buffer shown by the popup output surface SHALL behave as a normal Emacs buffer, allowing the user to scroll it, set a region, and copy text from it.

#### Scenario: Scroll and copy
- **WHEN** the user moves point into the popup buffer, sets a region, and copies
- **THEN** the selected text is placed on the kill ring

### Requirement: Reuse one buffer per output kind
The system SHALL reuse a single buffer per kind identifier. A new render with the same kind SHALL replace the previous content in that buffer and reuse its window rather than creating a new one.

#### Scenario: Re-render replaces content
- **WHEN** the command is invoked twice with the same kind identifier and different content
- **THEN** the second render replaces the first content in the same buffer and window

#### Scenario: Different kinds use different buffers
- **WHEN** the command is invoked with two different kind identifiers
- **THEN** each kind is rendered in its own dedicated buffer
