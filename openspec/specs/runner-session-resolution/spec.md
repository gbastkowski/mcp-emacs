## Purpose

Resolve which live Claude runner session receives a send when several may
exist, discovering sessions from live buffers (registry-less) and picking a
single target by project and window-visibility priority, prompting only when
the winning tier is ambiguous.

## Requirements

### Requirement: Runner sessions are discovered from live buffers

The system SHALL determine the set of available Claude runner sessions by
scanning live buffers whose names match the runner naming pattern
(`*claude:<project>:<n>*`), not from a stored registry. Each such buffer's
project SHALL be derived from that buffer's own `default-directory`
resolved to a project root.

#### Scenario: Session survives a registry-less reload

- **WHEN** a `*claude:<project>*` runner buffer is live but no in-memory
  session registry entry exists for it (e.g. after reloading the library)
- **THEN** the buffer is still discovered as an available session

#### Scenario: Dead buffers are not sessions

- **WHEN** scanning for sessions and a former runner buffer has been killed
- **THEN** it is not included among the available sessions

### Requirement: Send target is resolved by project and visibility priority

When sending keys or text, the system SHALL resolve exactly one target
runner session from the available sessions using this priority order,
where "same project" means the session's resolved project root equals the
current buffer's resolved project root, and "visible" means the session
buffer is displayed in some window:

1. same project AND visible
2. same project AND hidden
3. any project AND visible
4. any project AND hidden

The system SHALL use the highest-priority non-empty tier as the candidate
set for the pick.

#### Scenario: Single same-project visible session

- **WHEN** exactly one runner session is visible and belongs to the
  current buffer's project
- **THEN** that session is the target without prompting

#### Scenario: One of several belongs to the current project

- **WHEN** multiple runner sessions are visible but only one belongs to the
  current buffer's project
- **THEN** that same-project session is the target without prompting

#### Scenario: Visible preferred over hidden within the same project

- **WHEN** the current project has both a visible and a hidden runner
  session
- **THEN** the visible one is chosen (tier 1 beats tier 2)

#### Scenario: Cross-project fallback when none match

- **WHEN** no runner session belongs to the current buffer's project but
  at least one session exists for another project
- **THEN** resolution falls back to the visible-first cross-project tiers

### Requirement: Ambiguous resolution prompts the user

The system SHALL prompt the user to choose (via `completing-read`) when the
highest-priority non-empty tier contains more than one candidate, and
SHALL send to the chosen session.

#### Scenario: Multiple same-project sessions

- **WHEN** the winning tier contains more than one session
- **THEN** the user is prompted to pick one and the send goes to the pick

#### Scenario: Exactly one candidate is not a prompt

- **WHEN** the winning tier contains exactly one session
- **THEN** no prompt is shown and that session is used

### Requirement: No available session yields a clear error

The system SHALL signal a clear `user-error` when no live runner session
exists at all, rather than silently doing nothing.

#### Scenario: No sessions anywhere

- **WHEN** a send is attempted and no live `*claude:<project>:<n>*` runner buffer exists
- **THEN** a `user-error` is signalled indicating there is no runner session

### Requirement: A multi-keystroke send resolves the target once

The system SHALL resolve the target session once per user-initiated send
operation, so operations that emit several keystrokes (e.g. text followed
by a submit) do not prompt more than once.

#### Scenario: Prompt-and-submit resolves once

- **WHEN** the user sends a prompt that emits the text and then a submit
  keystroke, and the winning tier is ambiguous
- **THEN** the user is prompted at most once for that operation
