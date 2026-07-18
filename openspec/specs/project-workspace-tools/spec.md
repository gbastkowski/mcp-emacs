## Purpose

Define the MCP project/workspace management tools: enumerate workspace
roots, list project files, switch the active project, and find a file
within the project. All tools use built-in `project.el` as their base and
use `projectile` opportunistically when it is loaded, adding no hard
dependency.

## Requirements

### Requirement: Workspace folders can be listed
The system SHALL expose an MCP tool named `get_workspace_folders` that returns the project/workspace roots Emacs currently knows about.

#### Scenario: Roots are known
- **WHEN** a client calls the workspace-folders tool and Emacs knows one or more project roots
- **THEN** the tool returns those root paths

#### Scenario: No known roots
- **WHEN** a client calls the workspace-folders tool and Emacs knows no project roots
- **THEN** the tool returns an empty list rather than raising an error

### Requirement: Project files can be listed
The system SHALL expose an MCP tool named `list_project_files` that returns the files tracked in the current project.

#### Scenario: Listing files of the active project
- **WHEN** a client calls the list-project-files tool while inside a project
- **THEN** the tool returns the paths of files tracked in that project

#### Scenario: Not inside a project
- **WHEN** a client calls the list-project-files tool from a buffer not inside a project
- **THEN** the tool returns a status message rather than raising an error

### Requirement: Active project can be switched
The system SHALL expose an MCP tool named `switch_project` that changes Emacs's active project so that subsequent tools operate in the selected project's context.

#### Scenario: Switching to a valid project
- **WHEN** a client calls the switch-project tool with a valid project root or identifier
- **THEN** Emacs's active project becomes that project and the tool confirms the switch

#### Scenario: Invalid project target
- **WHEN** a client calls the switch-project tool with a path that is not a project
- **THEN** the tool returns a status message rather than raising an error, and the active project is unchanged

### Requirement: A file can be found within the project
The system SHALL expose an MCP tool named `find_file_in_project` that resolves a file by name within the current project and opens it.

#### Scenario: File exists in the project
- **WHEN** a client calls the find-file-in-project tool with a name that matches a project file
- **THEN** the tool opens the matching file and returns its resolved path

#### Scenario: No match
- **WHEN** a client calls the find-file-in-project tool with a name that matches no project file
- **THEN** the tool returns a status message rather than raising an error

### Requirement: Project tools work without a hard projectile dependency
The project/workspace tools SHALL use built-in `project.el` as their base and use `projectile` only when it is already loaded, so the tools function with no additional package dependency.

#### Scenario: projectile not loaded
- **WHEN** the project tools run in an Emacs where `projectile` is not loaded
- **THEN** they operate using `project.el` and do not error for lack of projectile

#### Scenario: projectile available
- **WHEN** the project tools run in an Emacs where `projectile` is loaded
- **THEN** they may use projectile for richer results while returning the same kind of information
