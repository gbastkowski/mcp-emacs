## Purpose

Maintains a per-session Org buffer that records the tool activity of the interactive Claude session
— tool calls, their arguments, and the accept/reject outcome of each diff review — plus per-session
run metadata, so the user has a structured, Org-native record of what Claude did without reading the
terminal scrollback.

## Requirements

### Requirement: One Org transcript buffer per session

The system SHALL maintain a dedicated Org-mode buffer per Claude session, named for the session's
project, and SHALL reuse that buffer for the lifetime of the session rather than creating a new one
per event.

#### Scenario: Transcript buffer created on first activity

- **WHEN** a Claude session produces its first recordable tool event and no transcript buffer exists
  for that session
- **THEN** an Org-mode buffer is created for the session
- **AND** subsequent events for the same session are appended to that same buffer

#### Scenario: Distinct sessions get distinct buffers

- **WHEN** two Claude sessions for different projects are active
- **THEN** each has its own transcript buffer
- **AND** events from one session are never written into the other's buffer

### Requirement: Record each tool call as an Org entry

The system SHALL append an Org heading for each tool call the session makes, including the tool name,
a timestamp, and the call's arguments in a form that is readable in Org.

#### Scenario: Tool call recorded

- **WHEN** the session invokes a tool
- **THEN** a new Org heading is appended to the transcript naming the tool and carrying a timestamp
- **AND** the tool's arguments are recorded under that heading

### Requirement: Record diff-review outcomes

The system SHALL record the outcome of each `openDiff` review — accepted or rejected — together with
the file the diff targeted, so the transcript reflects what was actually written.

#### Scenario: Diff accepted

- **WHEN** the user accepts an `openDiff` review
- **THEN** the transcript entry for that diff records the accepted outcome and the target file

#### Scenario: Diff rejected

- **WHEN** the user rejects an `openDiff` review (or it is otherwise dismissed unchanged)
- **THEN** the transcript entry for that diff records the rejected outcome and the target file

### Requirement: Record per-session run metadata

The system SHALL record run metadata for the session in an Org properties drawer, including at least
the session start time and the workspace root, and SHALL note when the session disconnects.

#### Scenario: Session connects

- **WHEN** a Claude session connects to the IDE surface
- **THEN** the transcript records the session start and workspace root as properties

#### Scenario: Session disconnects

- **WHEN** the session's connection closes
- **THEN** the transcript records that the session ended

### Requirement: Do not alter tool-approval behavior

The transcript SHALL be a passive record: recording an event MUST NOT change whether or how a tool
call is approved, executed, or answered. Approval remains the interactive diff review.

#### Scenario: Recording does not gate execution

- **WHEN** the transcript records a tool call or its outcome
- **THEN** the recording does not block, delay beyond rendering, or alter the tool call's approval or
  execution
- **AND** if transcript rendering fails, the session's tool calls are still answered normally

### Requirement: Scope limited to tool activity

In this version the transcript SHALL record tool activity and run metadata only; assistant prose is
out of scope and is not required to appear in the transcript.

#### Scenario: Assistant prose not required

- **WHEN** the session produces assistant prose that is visible only in the terminal
- **THEN** the transcript is not required to contain that prose
- **AND** the absence of prose is not treated as an error
