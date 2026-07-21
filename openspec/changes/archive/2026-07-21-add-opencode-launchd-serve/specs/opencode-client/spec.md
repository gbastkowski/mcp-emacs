## MODIFIED Requirements

### Requirement: Client connects to a running opencode server
The system SHALL connect to an `opencode serve` HTTP endpoint at a configurable host and port, verify it with a health check, and support an optional server password for HTTP basic auth. The password MAY be configured directly or resolved by running a configured shell command and using its trimmed standard output, so it can come from a secret store. When starting a server on demand, the client SHALL, if a launchd label is configured, start it by kickstarting that launchd agent (so the server is owned by launchd and outlives Emacs); otherwise it MAY start the server as a child process.

#### Scenario: Healthy server
- **WHEN** the client connects to a reachable opencode server
- **THEN** the health check succeeds and the client is ready to issue requests

#### Scenario: Server not reachable
- **WHEN** the client cannot reach the configured host/port
- **THEN** the client reports a clear connection error rather than failing opaquely

#### Scenario: Password from a direct value
- **WHEN** a password is configured directly
- **THEN** the client authenticates with HTTP basic auth using that value

#### Scenario: Password from a command
- **WHEN** no direct password is set but a password command is configured
- **THEN** the client runs the command and authenticates with its trimmed output

#### Scenario: No password configured
- **WHEN** neither a direct password nor a password command is configured
- **THEN** the client sends no authorization header

#### Scenario: On-demand start via launchd
- **WHEN** the user starts the server on demand and a launchd label is configured
- **THEN** the client kickstarts that launchd agent rather than spawning a child process
