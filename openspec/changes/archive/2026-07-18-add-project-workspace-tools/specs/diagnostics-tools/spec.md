## ADDED Requirements

### Requirement: Buffer diagnostics tool reports current-buffer code diagnostics
The system SHALL expose an MCP tool named `get_buffer_diagnostics` that returns the code diagnostics for the current buffer, auto-detecting the active checker (Flycheck or Flymake).

#### Scenario: Buffer has diagnostics
- **WHEN** a client calls the buffer diagnostics tool while the current buffer has Flycheck or Flymake diagnostics
- **THEN** the tool returns those diagnostics with location and severity information

#### Scenario: No checker active
- **WHEN** a client calls the buffer diagnostics tool and neither Flycheck nor Flymake is active in the current buffer
- **THEN** the tool returns a status message indicating no checker is active, rather than raising an error

#### Scenario: Renamed from get_diagnostics
- **WHEN** a client that previously used `get_diagnostics` calls `get_buffer_diagnostics`
- **THEN** it receives the same current-buffer code-diagnostics behavior under the new name

### Requirement: Project diagnostics tool aggregates code diagnostics across the project
The system SHALL expose an MCP tool named `get_project_diagnostics` that aggregates code diagnostics across the current project: from all live project buffers (Flycheck/Flymake) and, when an eglot or lsp-mode session is active, the LSP workspace diagnostics.

#### Scenario: Diagnostics across open project buffers
- **WHEN** a client calls the project diagnostics tool and several project buffers hold diagnostics
- **THEN** the tool returns the aggregated diagnostics, each attributed to its file

#### Scenario: LSP workspace diagnostics included when available
- **WHEN** a client calls the project diagnostics tool while an eglot/lsp-mode workspace session is active
- **THEN** the tool includes the LSP workspace diagnostics in the aggregated result

#### Scenario: Unopened non-LSP files are not covered
- **WHEN** a project contains files that are neither open in a buffer nor covered by an active LSP session
- **THEN** the tool does not report diagnostics for those files, and this limitation is documented in the tool description

#### Scenario: Not inside a project
- **WHEN** a client calls the project diagnostics tool from a buffer that is not inside a project
- **THEN** the tool returns a status message rather than raising an error
