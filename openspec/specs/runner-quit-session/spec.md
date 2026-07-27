## Purpose

Provide a command to gracefully quit a resolved Claude runner session,
falling back to a force-kill after a timeout, and clean up the session's
buffer so no process or buffer remains.

## Requirements

### Requirement: Gracefully quit a resolved runner session

The system SHALL provide a command that resolves a target runner session
using the same priority as input commands (see `runner-session-resolution`:
same-project and visible first, prompting when the winning tier is
ambiguous) and initiates a graceful quit of that session's Claude CLI by
sending the CLI quit sequence (Ctrl-C twice) to its terminal.

#### Scenario: Quit sends the CLI quit sequence

- **WHEN** the user invokes the quit command and a target session resolves
- **THEN** the CLI quit sequence (two Ctrl-C characters) is delivered to
  that session's terminal

#### Scenario: No live session

- **WHEN** the user invokes the quit command and no live runner session
  exists anywhere
- **THEN** a `user-error` is signalled and nothing is killed

### Requirement: Force-kill fallback after a timeout

The system SHALL wait a configurable timeout
(`mcp-emacs-run-quit-timeout`, in seconds, default 10) after sending the
quit sequence, without blocking Emacs, and if the session's process is
still live when the timeout elapses it SHALL force-kill that process.

#### Scenario: CLI exits on its own before the timeout

- **WHEN** the CLI process exits on its own after receiving the quit
  sequence and before the timeout elapses
- **THEN** the system does not force-kill it

#### Scenario: CLI does not exit within the timeout

- **WHEN** the CLI process is still live when the timeout elapses
- **THEN** the system force-kills the process

### Requirement: The session buffer is removed after quitting

The system SHALL remove the session's buffer once the quit has completed
(whether the CLI exited on its own or was force-killed), so the end state
has no process and no buffer for that session.

#### Scenario: Buffer removed after graceful exit

- **WHEN** the CLI exits on its own after the quit sequence
- **THEN** the session buffer is killed

#### Scenario: Buffer removed after force-kill

- **WHEN** the process is force-killed at the timeout
- **THEN** the session buffer is killed

#### Scenario: Buffer already gone is not an error

- **WHEN** the timeout handler runs but the session buffer has already been
  killed
- **THEN** no error is signalled
