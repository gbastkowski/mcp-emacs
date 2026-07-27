## ADDED Requirements

### Requirement: Select and resume a past session from a native picker
The system SHALL provide a command that lists the current project's past Claude sessions from the on-disk transcript store and lets the user pick one to resume. The chosen session SHALL be launched by resuming it by its session id. When the project has no past sessions, the command SHALL report this and SHALL NOT launch a session.

#### Scenario: Picking a past session
- **WHEN** the user invokes resume-select in a project that has past sessions and chooses one
- **THEN** the runner launches resuming that session by its session id

#### Scenario: No past sessions
- **WHEN** the user invokes resume-select in a project with no past sessions on disk
- **THEN** the command reports that there are no past sessions and launches nothing

### Requirement: Locate the project's transcript store
The system SHALL locate a project's transcript directory under a configurable Claude projects root by deriving the directory name from the project's absolute root path. The session id SHALL be the transcript file's name without its extension.

#### Scenario: Deriving the store directory
- **WHEN** the store directory is derived for a project root
- **THEN** it is the project root's absolute path, with path separators and dots replaced, located under the configured Claude projects root

### Requirement: Present sessions most-recent first with a readable label
The system SHALL order candidate sessions by recency (most recent first) and label each with a relative timestamp and a short preview drawn from the session's first genuine user prompt. Building a candidate SHALL NOT require reading the entire transcript. Injected command/caveat blocks and non-textual content SHALL be skipped when choosing the preview; when no genuine prompt is found near the start of the transcript, the session id SHALL be used as the label.

#### Scenario: Label from the first real prompt
- **WHEN** a session's transcript begins with a genuine user prompt
- **THEN** the candidate's label includes a relative timestamp and a truncated preview of that prompt

#### Scenario: Skipping injected content
- **WHEN** a session's early user entries are injected command or caveat blocks, or non-textual content
- **THEN** those entries are skipped and a later genuine prompt is used, or the session id when none is found

#### Scenario: Ordering
- **WHEN** multiple past sessions exist
- **THEN** they are offered most-recent first
