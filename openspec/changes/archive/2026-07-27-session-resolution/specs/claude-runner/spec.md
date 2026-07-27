## MODIFIED Requirements

### Requirement: Manage per-project runner sessions
The system SHALL support multiple concurrent runner sessions per project.
Each session's buffer SHALL be named `*claude:<project>:<n>*`, where `<n>`
is a positive integer allocated per project starting at 1 (the lowest
number not currently in use by a live session for that project). The
system SHALL provide a command to start a new session (always allocating a
fresh number), and commands to list, switch to, and kill sessions. The set
of live sessions SHALL be derived from the live runner buffers themselves
(matched by name and each buffer's own project directory), not from a
separately maintained root-to-buffer registry.

#### Scenario: Starting allocates a new numbered session
- **WHEN** the user starts a new runner and the project already has a live session numbered 1
- **THEN** a new session is started in buffer `*claude:<project>:2*` without disturbing session 1

#### Scenario: Numbering fills the lowest free slot
- **WHEN** the user starts a new runner and sessions 1 and 3 are live but 2 was killed
- **THEN** the new session reuses number 2

#### Scenario: Listing and switching
- **WHEN** the user lists sessions and selects one
- **THEN** the runner shows that session's buffer

#### Scenario: Killing a session
- **WHEN** the user kills a session
- **THEN** the runner terminates the CLI process and cleans up its buffer

#### Scenario: Sessions discoverable without a registry
- **WHEN** a runner buffer is live but no in-memory registry entry exists for it
- **THEN** the session is still listed, switchable, and killable
