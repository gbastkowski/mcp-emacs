## ADDED Requirements

### Requirement: Wait tool blocks until the session file changes or a timeout elapses
The system SHALL expose an MCP tool that accepts a session task file path, a baseline change token, and a timeout, and returns when the file's buffer has changed relative to the baseline token or when the timeout elapses.

#### Scenario: Change occurs during the wait
- **WHEN** a client waits with a baseline token and the file's buffer is edited before the timeout
- **THEN** the tool returns indicating a change occurred

#### Scenario: Timeout with no change
- **WHEN** a client waits with a baseline token and no edit occurs before the timeout
- **THEN** the tool returns indicating no change occurred, rather than raising an error

### Requirement: Changes since the baseline are not missed
When the file's buffer has already changed past the baseline token at the time the wait tool is called, the tool SHALL return immediately indicating a change, without waiting.

#### Scenario: Edit made between read and wait
- **WHEN** the buffer is edited after the client obtained its baseline token but before it calls the wait tool
- **THEN** the wait tool returns immediately indicating a change occurred

### Requirement: Waiting does not block the Emacs event loop
While waiting, the tool SHALL yield to the Emacs event loop so that human edits, timers, and other MCP tool calls continue to be processed.

#### Scenario: Other work proceeds during a wait
- **WHEN** the wait tool is waiting
- **THEN** edits to the file's buffer are still applied and observed, allowing the wait to detect them

### Requirement: Wake returns the change flag and the current session view
On return, the tool SHALL provide whether a change occurred, an updated change token, and the current session view (task heading, session id, status, and TODO checklist).

#### Scenario: Reacting in a single call
- **WHEN** the wait tool returns after a change
- **THEN** the response includes the change indication, a new change token, and the current session contents

### Requirement: Timeout is bounded
The tool SHALL apply a default timeout when none is given and MUST cap the timeout at a defined maximum, so a wait cannot hang indefinitely.

#### Scenario: No timeout provided
- **WHEN** a client calls the wait tool without a timeout
- **THEN** the tool applies the default timeout

#### Scenario: Excessive timeout requested
- **WHEN** a client requests a timeout above the maximum
- **THEN** the tool waits no longer than the maximum
