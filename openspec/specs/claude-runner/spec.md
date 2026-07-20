## Purpose

Define a terminal runner that launches and manages the Claude Code CLI inside
Emacs: project-aware launch in an eat terminal, one primary session per project
(list/switch/kill), a managed side window, and continue/resume — with editor
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
The system SHALL keep at most one primary runner session per project, name its buffer distinctly (for example `*claude:<project>*`), and provide commands to list, switch to, and kill sessions.

#### Scenario: Reusing a project's session
- **WHEN** the user starts the runner for a project that already has a live session
- **THEN** the runner switches to the existing session rather than starting a duplicate

#### Scenario: Listing and switching
- **WHEN** the user lists sessions and selects one
- **THEN** the runner shows that session's buffer

#### Scenario: Killing a session
- **WHEN** the user kills a session
- **THEN** the runner terminates the CLI process and cleans up its buffer

### Requirement: Manage the runner window
The system SHALL provide commands to show, hide, and toggle the runner window, using a side-window placement, with control over whether focus moves to the runner.

#### Scenario: Toggling visibility
- **WHEN** the user toggles the runner window while it is visible
- **THEN** the window is hidden, and toggling again shows it

#### Scenario: Side-window placement
- **WHEN** the runner window is shown
- **THEN** it appears in a side window rather than replacing the user's main window

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
