## Purpose

Lets a user send a prompt to the current project's interactive Claude session from ordinary
Emacs input — the minibuffer, the active region, or the current buffer — without typing into the
runner's terminal buffer.

## ADDED Requirements

### Requirement: Send a prompt from the minibuffer

The system SHALL provide an interactive command that reads a prompt string from the minibuffer and
delivers it to the current project's running Claude session, submitting it so the session begins
responding without the user having to switch to the terminal buffer.

#### Scenario: Prompt entered in the minibuffer

- **WHEN** the user invokes the remote-prompt command and types a non-empty string at the minibuffer
- **THEN** the string is delivered to the current project's runner session and submitted
- **AND** focus is not required to move to the terminal buffer for the session to begin responding

#### Scenario: Empty or whitespace-only prompt is not sent

- **WHEN** the user invokes the remote-prompt command and submits an empty or whitespace-only string
- **THEN** nothing is sent to the session
- **AND** the command reports that no prompt was provided

### Requirement: Seed the prompt from the active region

The system SHALL, when a region is active, seed the minibuffer with the region text so the user can
edit or confirm it before it is sent, rather than sending the raw selection immediately.

#### Scenario: Region active

- **WHEN** a region is active and the user invokes the remote-prompt command
- **THEN** the minibuffer is pre-filled with the region text
- **AND** the user may edit it before confirming
- **AND** on confirmation the resulting text is delivered to the session and submitted

### Requirement: Send the whole current buffer as the prompt

The system SHALL provide a way to send the entire current buffer as the prompt, so the user can hand
a whole file's contents to the session without selecting it. An empty or whitespace-only buffer is
not sent.

#### Scenario: Whole buffer sent

- **WHEN** the user invokes the send-buffer variant of the remote-prompt command in a non-empty
  buffer
- **THEN** the entire buffer text is delivered to the current project's runner session and submitted

#### Scenario: Empty buffer is not sent

- **WHEN** the user invokes the send-buffer variant in an empty or whitespace-only buffer
- **THEN** nothing is sent to the session
- **AND** the command reports that there was nothing to send

### Requirement: Require a live session

The system SHALL require an already-running Claude session for the current project and SHALL NOT
launch one implicitly.

#### Scenario: No session running

- **WHEN** the user invokes the remote-prompt command and the current project has no running Claude
  session
- **THEN** the command reports that no session is available
- **AND** no prompt is sent and no session is launched

#### Scenario: Session running

- **WHEN** the user invokes the remote-prompt command and the current project has exactly one
  running Claude session
- **THEN** the prompt is delivered to that session

### Requirement: Resolve the target session unambiguously

The system SHALL resolve which session receives the prompt using the same project-scoped session
resolution the runner already uses, and SHALL prompt the user to choose when more than one candidate
session exists.

#### Scenario: Multiple sessions for the project

- **WHEN** the current project has more than one running Claude session and the user invokes the
  remote-prompt command
- **THEN** the user is asked to choose the target session
- **AND** the prompt is delivered to the chosen session
