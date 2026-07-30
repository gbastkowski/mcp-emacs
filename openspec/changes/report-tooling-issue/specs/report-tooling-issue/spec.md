## Purpose

Lets a user file a bug report or feature request about mcp-emacs itself — the MCP server's tools or a
plugin skill — as a GitHub issue on the mcp-emacs repository, from inside the assistant, without
hand-writing the issue or leaving the session.

## ADDED Requirements

### Requirement: File a tooling issue as a GitHub issue

The system SHALL provide a `report_tooling_issue` tool that creates a GitHub issue on the mcp-emacs
repository from a supplied title and optional description, and SHALL return the URL of the created
issue.

#### Scenario: Issue filed with title and description

- **WHEN** the tool is called with a title and a description
- **THEN** a GitHub issue is created on the mcp-emacs repository with that title and body
- **AND** the tool returns the URL of the created issue

#### Scenario: Title is required

- **WHEN** the tool is called without a title
- **THEN** no issue is created
- **AND** the tool reports that a title is required

### Requirement: Optional category applied as a label

The system SHALL accept an optional `kind` categorizing the report as one of `bug`, `feature`,
`skill`, or `server`, and SHALL apply the chosen value as a label on the created issue. When `kind` is
omitted, the issue is created without a category label.

#### Scenario: Kind provided

- **WHEN** the tool is called with `kind` set to one of the accepted values
- **THEN** the created issue carries that value as a label

#### Scenario: Kind omitted

- **WHEN** the tool is called with no `kind`
- **THEN** the issue is still created
- **AND** no category label is required for the call to succeed

#### Scenario: Invalid kind

- **WHEN** the tool is called with a `kind` outside the accepted set
- **THEN** the call is rejected with a message naming the accepted values
- **AND** no issue is created

### Requirement: Resilient filing chain

The system SHALL attempt to create the issue through more than one mechanism so that filing succeeds
whenever any one of them is available, trying in order: the GitHub MCP tool if available, then the
`gh` CLI, then a direct `gh api` call. If none is available, the system SHALL report that it could
not file the issue and SHALL surface the issue title and body so the user can file it manually.

#### Scenario: Preferred mechanism available

- **WHEN** the GitHub MCP tool is available
- **THEN** the issue is created through it
- **AND** the lower-priority mechanisms are not attempted

#### Scenario: Fallback to the CLI

- **WHEN** the GitHub MCP tool is not available but the `gh` CLI is
- **THEN** the issue is created through the `gh` CLI

#### Scenario: No mechanism available

- **WHEN** none of the filing mechanisms is available
- **THEN** no issue is created
- **AND** the system reports the failure and returns the composed title and body for manual filing

### Requirement: Report about mcp-emacs, not arbitrary repositories

The tool SHALL be scoped to filing issues about mcp-emacs itself and SHALL target the mcp-emacs
repository; it is not a general-purpose issue creator for arbitrary repositories.

#### Scenario: Target repository is fixed

- **WHEN** the tool creates an issue
- **THEN** the issue is created on the mcp-emacs repository
- **AND** the caller does not choose an arbitrary target repository

### Requirement: Guided reporting via a skill

The system SHALL provide a `report-issue` skill that guides the user through reporting: it classifies
the report (a server-tool bug, a skill/prompt issue, or a feature request), drafts a concise issue
(title plus what-happened / expected / reproduction), confirms the draft with the user before filing,
files it via the `report_tooling_issue` tool, and reports back the resulting issue URL.

#### Scenario: Guided report end to end

- **WHEN** the user asks to report a bug or feature request about the tooling and the skill runs
- **THEN** the skill classifies the report and drafts a title and body
- **AND** the skill confirms the draft with the user before filing
- **AND** on confirmation the skill files the issue via `report_tooling_issue` and reports the URL

#### Scenario: User declines the draft

- **WHEN** the user does not confirm the drafted issue
- **THEN** no issue is filed
