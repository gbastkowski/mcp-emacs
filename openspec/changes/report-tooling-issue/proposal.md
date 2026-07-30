## Why

The sibling GitLab AI-tooling repos recently shipped a "report a tooling issue" feature: a user who
hits a bug or wants a feature in the tooling itself can file it from inside the assistant, without
leaving the session. mcp-emacs has no equivalent — a user who finds a broken tool or a clumsy skill
has to context-switch to GitHub and hand-write an issue.

This change ports that feature to mcp-emacs, adapted from GitLab (two repos, fault-domain routing) to
mcp-emacs's single GitHub repo (`gbastkowski/mcp-emacs`).

## What Changes

- Add a **`report_tooling_issue`** MCP tool that files a GitHub issue against `gbastkowski/mcp-emacs`.
  - Params: `title` (required), `description` (optional), `kind` (optional enum: `bug` / `feature` /
    `skill` / `server`, applied as a GitHub label).
  - Filing uses a fallback chain: the GitHub MCP tool if available → the `gh` CLI → `gh api` directly.
  - Returns the created issue URL.
- Add a **`report-issue`** skill that orchestrates the flow: classify the report, draft a lean issue,
  **confirm with the user**, file it via the tool, and report back the URL.
- No fault-domain router (the GitLab `get_origin` tool). mcp-emacs is one repo, so there is nothing to
  route between; the `kind` label carries the server-vs-skill signal instead.

## Capabilities

### New Capabilities

- `report-tooling-issue`: file a bug report or feature request about mcp-emacs itself (the MCP server
  tools or a plugin skill) as a GitHub issue on `gbastkowski/mcp-emacs`, from inside the assistant,
  via a resilient filing chain.

### Modified Capabilities

<!-- None. This adds a new tool + skill; it does not change any existing capability's requirements. -->

## Impact

- **New elisp**: a filing helper (e.g. `mcp-emacs-report-tooling-issue`) plus a new tool descriptor in
  `mcp-emacs-server--tools` (`elisp/mcp-emacs-server.el`).
- **New skill**: `skills/report-issue/SKILL.md` (or the repo's skill location).
- **External dependency**: GitHub issue creation via one of — the `github` MCP server, the `gh` CLI,
  or `gh api`. `gh` is already installed and authenticated in the dev environment.
- **Reuses**: the existing MCP tool-registration shape (`:name`/`:description`/`:schema`/`:handler`
  plists, `--obj`/`--prop` schema helpers).
- **Out of scope**: fault-domain routing / a `get_origin`-style tool; issue templates; multi-repo
  targeting.

Ports the feature from mcp-gitlab (`report_tooling_issue`), mcp-jira-confluence (`get_origin`), and
jira-assistant (`report-issue` skill). Full context: issue #26.
