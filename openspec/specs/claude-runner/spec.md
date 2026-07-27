## Purpose

Define a terminal runner that launches and manages the Claude Code CLI inside
Emacs: project-aware launch in an eat terminal, one primary session per project
(list/switch/kill), a managed directional window, and continue/resume — with editor
integration provided to the CLI through the mcp-emacs MCP server rather than the
IDE WebSocket protocol.

## Requirements

### Requirement: Launch the Claude CLI in an Emacs terminal
The system SHALL launch the `claude` CLI inside an Emacs terminal buffer using eat as the terminal backend, with the working directory set to the current project root (via `project.el`), so the CLI runs in the project's context and reaches editor tools through mcp-emacs over MCP.

#### Scenario: Launching in a project
- **WHEN** the user starts the runner from a buffer inside a project
- **THEN** the CLI starts in an eat terminal whose working directory is the project root

#### Scenario: eat not available
- **WHEN** eat is not available
- **THEN** the runner reports that it requires eat rather than failing opaquely

#### Scenario: Configurable executable and flags
- **WHEN** the user has configured a custom `claude` executable path or extra CLI flags
- **THEN** the runner launches that executable with those flags

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

### Requirement: Manage the runner window
The system SHALL provide commands to show, hide, and toggle the runner window, placing the buffer in an ordinary (non-dedicated) window in a configurable direction, with control over whether focus moves to the runner.

#### Scenario: Toggling visibility
- **WHEN** the user toggles the runner window while it is visible
- **THEN** the window is hidden, and toggling again shows it

#### Scenario: Directional placement
- **WHEN** the runner window is shown
- **THEN** it appears in an ordinary window placed in the configured direction (default to the right), so it can be split, navigated, and closed like any other window rather than a dedicated side window

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

### Requirement: Continue and resume prior conversations
The system SHALL support starting the CLI with continue and resume options so the user can pick up a previous conversation.

#### Scenario: Continue the most recent conversation
- **WHEN** the user starts the runner in continue mode
- **THEN** the CLI is launched with its continue option

#### Scenario: Resume a chosen conversation
- **WHEN** the user starts the runner in resume mode
- **THEN** the CLI is launched with its resume option so a prior conversation can be selected

### Requirement: Runner adds no hard package dependency
The runner SHALL use eat only when it is available, loaded as a soft/optional dependency, so installing mcp-emacs does not require eat.

#### Scenario: eat present
- **WHEN** eat is loaded
- **THEN** the runner uses it as the terminal backend

#### Scenario: eat absent
- **WHEN** eat is not loaded
- **THEN** loading mcp-emacs still succeeds and the runner reports that it needs eat only when a runner command is invoked
