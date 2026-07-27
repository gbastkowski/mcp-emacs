## ADDED Requirements

### Requirement: Emacs registers as a Claude Code IDE and launches Claude Code against it
The system SHALL make a running Emacs act as the Claude Code IDE for a workspace by (a) launching the Claude Code process with the IDE integration environment (`CLAUDE_CODE_SSE_PORT` set to the WebSocket server port and `ENABLE_IDE_INTEGRATION` enabled) so it connects back to Emacs, and (b) publishing a discovery lockfile at `~/.claude/ide/<port>.lock` describing the IDE. The lockfile SHALL include the Emacs process id, the workspace folder(s), an IDE name, and the WebSocket transport marker, and SHALL be removed when the IDE surface stops.

#### Scenario: Claude Code launched with IDE environment
- **WHEN** the IDE integration surface starts Claude Code for a project
- **THEN** the Claude Code process is started **interactively** (in a terminal buffer, not headless `-p`) with `CLAUDE_CODE_SSE_PORT` set to the IDE WebSocket port and IDE integration enabled, and it connects to the Emacs WebSocket server

#### Scenario: Workspace trust does not block the connection
- **WHEN** Claude Code shows its first-run "do you trust this folder?" prompt for the workspace
- **THEN** the integration ensures the workspace is trusted so Claude Code proceeds to connect rather than waiting at the prompt

#### Scenario: Lockfile published on start
- **WHEN** the IDE integration surface is started for a project
- **THEN** a lockfile exists at `~/.claude/ide/<port>.lock` containing the Emacs pid, the project workspace folder, an IDE name, and a `ws` transport marker

#### Scenario: Lockfile removed on stop
- **WHEN** the IDE integration surface is stopped or Emacs exits normally
- **THEN** the corresponding `~/.claude/ide/<port>.lock` file no longer exists

### Requirement: IDE surface serves the diff tools over WebSocket
The system SHALL run a WebSocket server that speaks Claude Code's IDE protocol (JSON-RPC 2.0; `initialize` echoing the protocol version Claude Code offers) and advertises the tools Claude Code invokes around native file edits: `openDiff`, `close_tab`, `closeAllDiffTabs`, and `getDiagnostics`. The surface SHALL respond to every tools/call Claude Code makes, because an unanswered call blocks the edit. The surface SHALL be opt-in and disabled by default, and SHALL not alter or replace the existing HTTP MCP server or its tools.

#### Scenario: Tools advertised to a connecting IDE client
- **WHEN** Claude Code connects to the advertised WebSocket port and negotiates a session
- **THEN** the IDE surface advertises `openDiff`, `close_tab`, `closeAllDiffTabs`, and `getDiagnostics`

#### Scenario: Pre-edit calls are answered so the edit proceeds
- **WHEN** Claude Code calls `closeAllDiffTabs` and `getDiagnostics` immediately before a native edit
- **THEN** the surface responds to both so Claude Code proceeds to call `openDiff` rather than blocking

#### Scenario: HTTP MCP server unaffected
- **WHEN** the IDE surface is enabled alongside the HTTP MCP server for the same project
- **THEN** the HTTP MCP server and its tools continue to function unchanged

#### Scenario: Surface off by default
- **WHEN** the user has not opted into the IDE surface
- **THEN** no WebSocket server runs and no `~/.claude/ide` lockfile is published by `mcp-emacs`

### Requirement: Native edits are reviewed via ediff before writing
When Claude Code calls `openDiff` during a native edit, the system SHALL present the proposed change in an interactive ediff session (current contents versus proposed contents) reusing the existing accept/reject review flow, and SHALL return a result that tells Claude Code whether the edit was applied. Accepting SHALL return an applied/saved result carrying the accepted content; rejecting or timing out SHALL return a rejected result and leave the file unchanged.

#### Scenario: Human accepts a native edit
- **WHEN** Claude Code calls `openDiff` for a native edit and the human accepts the proposal in the ediff session
- **THEN** the tool returns a `FILE_SAVED` result with the accepted content and the change is applied

#### Scenario: Human rejects a native edit
- **WHEN** Claude Code calls `openDiff` for a native edit and the human rejects the proposal
- **THEN** the tool returns a `DIFF_REJECTED` result and the file is left unchanged

#### Scenario: Review times out
- **WHEN** the human neither accepts nor rejects before the diff review timeout elapses
- **THEN** the tool abandons the ediff session, leaves the file unchanged, and returns a `DIFF_REJECTED` result

### Requirement: Diff tabs can be closed by Claude Code
The system SHALL handle Claude Code's `close_tab` and `closeAllDiffTabs` calls by tearing down the corresponding ediff session(s) and cleaning up their buffers. `close_tab` SHALL target the session identified by its tab name; `closeAllDiffTabs` SHALL close all open diff sessions for the current connection.

#### Scenario: Close a single diff tab
- **WHEN** Claude Code calls `close_tab` with the name of an open diff tab
- **THEN** the matching ediff session is torn down and its buffers cleaned up

#### Scenario: Close all diff tabs
- **WHEN** Claude Code calls `closeAllDiffTabs`
- **THEN** all open diff sessions for the current connection are torn down and their buffers cleaned up
