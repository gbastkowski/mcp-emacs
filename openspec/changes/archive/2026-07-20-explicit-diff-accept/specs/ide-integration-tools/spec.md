## MODIFIED Requirements

### Requirement: Interactive diff/apply tool presents a proposal via ediff
The system SHALL expose an MCP tool that accepts a file path and proposed new content, opens an `ediff` session comparing the file's current content against the proposal, and lets the human review, edit, accept, or reject the proposal interactively before the tool returns. The outcome SHALL be determined by an explicit human accept or reject action during the session, not by whether the file's buffer content changed. Accepting SHALL apply the proposal (or the human's edited version of it) to the file's buffer; rejecting SHALL leave the buffer unchanged. Quitting the session without an explicit accept SHALL be treated as a rejection.

#### Scenario: Accepting the proposal as-is
- **WHEN** a client calls the diff tool with a path and new content and the human accepts the proposal without editing it
- **THEN** the tool applies the proposed content to the buffer and returns a status of `applied` together with the final content

#### Scenario: Rejecting the proposal
- **WHEN** the human rejects the proposal during the ediff session
- **THEN** the tool leaves the file's buffer unchanged and returns a status of `rejected`

#### Scenario: Human edits the proposal before accepting
- **WHEN** the human edits the proposed content during the ediff session and then accepts
- **THEN** the tool returns a status of `applied` with the human-edited content, not the original proposal

#### Scenario: Quitting without accepting
- **WHEN** the human quits the ediff session without explicitly accepting the proposal
- **THEN** the tool leaves the file's buffer unchanged and returns a status of `rejected`
