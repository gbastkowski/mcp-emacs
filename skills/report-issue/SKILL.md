---
name: report-issue
description: Report a bug or feature request about mcp-emacs itself — the MCP server's tools or a plugin skill — as a GitHub issue on gbastkowski/mcp-emacs. Use when the user says a tool, skill, or prompt from this tooling misbehaved, is missing something, or they want it filed as an issue. Not for filing issues in the user's own project repos.
---

# Report an mcp-emacs tooling issue

Use this when the problem is with **mcp-emacs itself** — a server tool that
misbehaved, a skill or prompt that read wrong, or a missing feature — and the
user wants it filed. This is *not* for creating issues in the user's own
project repositories; for that, file against their repo directly.

Everything is filed on one repo: `gbastkowski/mcp-emacs`. There is no
fault-domain routing — the category is captured as a label, not a repo choice.

## Workflow

### 1. Classify

Decide what kind of report this is:

- **`server`** — an MCP server tool misbehaved: wrong output, a crash, a bad
  edit, a tool that did the wrong thing.
- **`skill`** — a skill or prompt read wrong: clumsy wording, a bad template,
  a workflow that asked for the wrong thing.
- **`bug`** — a defect that doesn't cleanly fit server-vs-skill.
- **`feature`** — a request for something new rather than a defect.

If it's ambiguous, ask **one** short question. Rule of thumb: wrong *result
from a tool* → `server`; wrong *thing the assistant said or asked* → `skill`.

### 2. Draft

Compose a lean issue:

- **Title** — short and specific.
- **Body** — What happened / Expected / Reproduction (the exact tool, skill,
  or prompt involved, and the steps). Keep it tight; skip boilerplate.

### 3. Confirm

Show the drafted title and body to the user and **confirm before filing**. If
the user doesn't confirm, file nothing.

### 4. File

Prefer whichever mechanism is available, in this order:

1. **The `github` MCP server**, if it's connected — create the issue on
   `gbastkowski/mcp-emacs` with the `github` tooling directly.
2. **The `report_tooling_issue` MCP tool** (mcp-emacs) otherwise — pass
   `title`, `description`, and `kind` (`bug` / `feature` / `skill` /
   `server`). It files via the `gh` CLI, falling back to `gh api`, and applies
   `kind` as a label best-effort. It returns `Created issue: <url>`.

If neither can file (no GitHub access at all), `report_tooling_issue` returns
the composed title and body for manual filing — hand that to the user with the
`https://github.com/gbastkowski/mcp-emacs/issues/new` link.

### 5. Report back

Tell the user the resulting issue URL (or the manual-filing text if it
couldn't be filed), and which `kind` it was tagged with.
