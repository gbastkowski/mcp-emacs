# MCP Emacs

Model Context Protocol (MCP) tooling for Emacs.

`mcp-emacs` runs an MCP server **inside your live Emacs session** and speaks MCP
over HTTP. There is no separate process and no `emacsclient` round-trip per
call: tool calls are dispatched directly to the helper functions, so they
observe the real buffers, windows, and Org state of the running session.

Longer term this is aimed at moving away from the chatbot request/response loop
toward a dynamic, AI-driven development environment where the human and the AI
work the same live artifacts together — see [`docs/VISION.md`](docs/VISION.md).

## Features

### Tools

| Tool                              | Description                                                                                |
|-----------------------------------|--------------------------------------------------------------------------------------------|
| `get_buffer_content`              | Get the content of the current Emacs buffer                                                |
| `get_buffer_filename`             | Get the filename associated with the current Emacs buffer                                  |
| `get_selection`                   | Get the current selection (region) in Emacs                                                |
| `open_file`                       | Open a file in the current Emacs window                                                    |
| `get_current_clocked_task`        | Get the Org task currently clocked in                                                      |
| `get_current_task_at_point`       | Get the current Org task at point                                                          |
| `edit_file_region`                | Replace text in a file by specifying start/end line & column coordinates (optionally save) |
| `insert_at_point`                 | Insert text at point or replace the current selection in the active buffer                 |
| `goto_line`                       | Jump to a specific line/column or navigate directly to a named function via imenu          |
| `toggle_org_todo`                 | Toggle the TODO keyword (or set a specific state) on the current Org heading               |
| `describe_flycheck_info_at_point` | Get diagnostics at cursor (Flycheck, falling back to Flymake)                              |
| `get_buffer_diagnostics`          | Get code diagnostics for the current buffer (Flycheck or Flymake, auto-detected)           |
| `get_project_diagnostics`         | Aggregate code diagnostics across open project buffers (LSP via Flymake); unopened files not covered |
| `get_error_context`               | Summarize contents of error-related buffers (*Messages*, *Warnings*, compilation logs)     |
| `save_buffer`                     | Save the current buffer if it is visiting a file                                           |
| `close_buffer`                    | Close the current buffer, optionally saving first                                          |
| `switch_buffer`                   | Switch to a named buffer                                                                    |
| `imenu_list_symbols`              | List the current buffer's symbols (functions, classes, variables) with line numbers        |
| `xref_find_references`            | Find references to an identifier (or the symbol at point) via xref                         |
| `xref_find_apropos`               | Find symbols matching a pattern across the project via xref apropos                        |
| `treesit_info`                    | Tree-sitter node info at point: node type, range, and ancestor chain                       |
| `apply_diff`                      | Propose new file content via an interactive ediff session; returns applied/rejected/timeout |
| `list_open_editors`               | List file-visiting buffers with their path, buffer name, and dirty flag                    |
| `check_document_dirty`            | Report whether the buffer visiting a file has unsaved changes                              |
| `project_info`                    | Project root, active file, and tracked file count                                          |
| `get_workspace_folders`           | List the project/workspace roots Emacs knows about                                         |
| `list_project_files`              | List the files tracked in the current project                                              |
| `switch_project`                  | Switch Emacs's active project so later tools operate in that context                       |
| `find_file_in_project`            | Resolve a file by name within the current project and open it                              |
| `diagnose_emacs`                  | Collect diagnostic info about the running Emacs (exec-path, LSP clients, …)                 |
| `get_env_vars`                    | List environment variables visible to Emacs                                                |
| `eval`                            | Evaluate an arbitrary Elisp expression in the current buffer context                       |
| `org_task_session`                | Read a session task Org file: task heading, session id, status, and TODO checklist         |
| `org_task_set_session_status`     | Set the session status (Org keyword) of a session task file                                |
| `org_task_set_item_status`        | Set a TODO item's Org keyword, identified by ID/CUSTOM_ID property or heading text          |
| `org_task_append_note`            | Append a progress note to the task body without altering existing content                  |
| `org_task_append_item`            | Append a new TODO item as a child under the task heading                                   |
| `org_task_wait_for_change`        | Block until the task file changes past a baseline token (or a timeout), then return it     |
| `report_tooling_issue`            | File a bug report or feature request about mcp-emacs itself as a GitHub issue               |
| `orgspec_new`                     | Scaffold a new orgspec change (`changes/<id>/change.org`)                                   |
| `orgspec_status`                  | Report task-checkbox completion for one change or all active changes                       |
| `orgspec_parse`                   | Read a change's delta as structured data (per-requirement op / area / scenarios)           |
| `orgspec_archive`                 | Fold a change's delta into `specs/` and move the change to archive                         |
| `orgspec_review`                  | Ediff a change's fold against the current specs before writing (writes nothing)            |
| `orgspec_validate`                | Run the hard-gate validator over a change; report problems or valid                        |
| `orgspec_advance`                 | Set a delta requirement's lifecycle TODO keyword (active / blocked / removed / done)       |
| `orgspec_agenda`                  | Register the in-flight-requirements agenda custom command                                  |

### orgspec — an org-native spec workflow

orgspec is a thin, dependency-free port of the load-bearing core of
[OpenSpec](https://github.com/Fission-AI/OpenSpec) — a structure parser and a
delta-fold — living natively in Org and Emacs Lisp instead of TypeScript over
Markdown. A change is spec-of-intent first: you describe *what* should change,
implement it, then fold that description into an accumulating source of truth.

Layout under the orgspec root (`orgspec/` by default):

- `specs/<area>.org` — the accumulating source of truth. Requirements are
  level-1 headlines, scenarios level-2.
- `changes/<id>/change.org` — one change: human sections (Intent / Scope /
  Approach / Tasks) plus a `* Delta` subtree. Each delta requirement is a
  level-2 headline tagged with its op (`:ADDED:` / `:MODIFIED:` / `:REMOVED:` /
  `:RENAMED:`) and an `:AREA:` property naming its target spec; scenarios are
  level-3.

The workflow is exposed both as slash commands and as the typed `orgspec_*` MCP
tools above:

| Command | Does |
|---|---|
| `/orgspec:propose` | scaffold a change and draft the whole `change.org` from a description |
| `/orgspec:new`     | scaffold an empty change from the template |
| `/orgspec:apply`   | implement the tasks, tick the checklist, advance each requirement's TODO keyword |
| `/orgspec:status`  | report `[x]`/`[ ]` task completion |
| `/orgspec:parse`   | read a change's delta as structured data |
| `/orgspec:review`  | ediff the fold against the current specs before writing — see it, don't trust it |
| `/orgspec:validate`| run the hard-gate validator (the same gate `archive` enforces) |
| `/orgspec:archive` | fold the delta into `specs/` and `git mv` the change to archive |

**The fold** is the load-bearing piece. It applies a change's delta in the fixed
order `RENAMED → REMOVED → MODIFIED → ADDED` via Org subtree surgery (not text
splicing), builds every affected spec in memory and validates the whole set
before writing anything (so a late failure leaves `specs/` untouched), guards
against a `MODIFIED` requirement silently dropping a scenario, and on re-level
into `specs/` strips the TODO keyword, op tag, and `:AREA:` while keeping any
`:IMPL:` drawer.

**Why Emacs, not a CLI:** delta requirements carry your *existing* Org TODO
keywords, so `apply` moves a requirement through its lifecycle (active / blocked
on a `[NEEDS CLARIFICATION]` marker / done) and one agenda custom command
becomes an in-flight-requirements dashboard — something a headless tool over
flat Markdown can't do for free.

orgspec deliberately drops what only serves multi-developer, multi-artifact
scale (conflict-free parallel changes, artifact DAGs, bulk operations). If
CI-enforced validation, many conflicting parallel changes, or team-enforced
structure ever become the requirement, OpenSpec proper stays the heavier,
battle-tested fallback. See [issue #5](https://github.com/gbastkowski/mcp-emacs/issues/5)
for the full design.



An AI coding harness and the human share one Org file as a live workspace: the
harness reports status into it (via the `org_task_*` tools) while the human
edits the same file in Emacs. The file's first heading is the task — its TODO
keyword is the session status, its `SESSION` property is the session id, and its
child headings are the checklist. All writes go through the live buffer and are
never saved automatically; the AI only updates items it can identify and never
reorders, deletes, or rewrites human-authored items.

For a cooperative loop, `org_task_session` returns a change token and
`org_task_wait_for_change` blocks (up to a timeout, without freezing Emacs)
until the human edits the file, then wakes with the change and the current
session view. The harness works, then waits for the human's next direction —
instead of only seeing edits when it happens to re-read.

### Report a tooling issue

When a tool or skill from mcp-emacs misbehaves — or you want a feature — the
`report_tooling_issue` tool files it as a GitHub issue on
`gbastkowski/mcp-emacs`, so you can report from inside the assistant instead of
switching to GitHub by hand. It takes a `title`, an optional `description`, and
an optional `kind` (`bug` / `feature` / `skill` / `server`) applied as a label.

Filing is resilient: it uses the `gh` CLI, falling back to `gh api`; when no
GitHub mechanism is available it hands back the composed issue text for manual
filing. The `report-issue` skill wraps this in a guided flow — classify, draft,
confirm, file, report the URL — and prefers the `github` MCP server when one is
connected. The target repo is fixed: this reports issues about mcp-emacs
itself, not arbitrary repositories.

This is the GitHub, single-repo counterpart to the "report a tooling issue"
feature in the sibling GitLab AI-tooling (see #26); there is no fault-domain
router because mcp-emacs is one repo.

### Shared agent-backend

`elisp/agent-backend.el` is the shared layer behind the two conversation
backends in this repository (issue #41).  Both `opencode-client.el` and
`claude-client.el` subclass its EIEIO base class `agent-backend', so the
backends are interchangeable from the user's point of view: the same
keybindings, the same event consumers, and the same Org transcript work
regardless of which backend is driving the session.

**The interface.**  The base class declares a `cl-defgeneric` lifecycle
interface -- `agent-backend-connect`, `-quit`, `-send`, `-interrupt`,
`-add-note`, `-note-policy`, `-reply-permission`, `-reply-question`,
`-list-sessions`, `-resume`, `-seed-history`, `-project-root`, and
`-render`.  The optional capabilities (permission/question replies,
sessions, resume, history seeding, project root, render) have no-op or
`user-error` defaults on the base class, so a minimal backend implements
only connect, quit, send, interrupt, add-note, and note-policy and
compiles without stubs.

**The event vocabulary.**  Every conversation event is published as a
plist with a `:kind' symbol on the abnormal hook
`agent-backend-event-functions', run with (BUFFER EVENT).  The shared
kinds are `started', `prompt', `text', `tool-use', `tool-result',
`finished', `interrupted', `note', `notes-delivered', `note-dropped',
`resumed', `permission-request', `question-request', and `error'.
Subscribers must ignore unknown kinds, so a new kind degrades to silence
rather than breaking a reader.  This is what lets the remote Org
transcript record both opencode and Claude sessions through one
subscriber.

**The mode.**  `agent-backend-mode' derives from `special-mode' and binds
the common actions in a shared keymap (`C-c C-s` send, `C-c C-i`
interrupt, `C-c C-n` add-note, `C-c C-q` quit, `C-c C-r` resume); each
backend's major mode derives from it and layers its own keys on top.

**Note policy.**  `agent-backend-note-policy' names how a human note
written mid-turn reaches the model.  opencode notes ARE steering prompts
(`:steer'), delivered immediately via its HTTP API; Claude keeps its
native interrupt-or-queue machinery (`:interrupt` when
`claude-client-note-interrupts' is on, `:queue` when off).

The two sections below describe what each concrete backend adds:
### opencode client

`elisp/opencode-client.el` is a native Emacs client for
[opencode](https://opencode.ai)'s local HTTP API. opencode runs headless
(`opencode serve`); the client drives it over HTTP and
renders the conversation incrementally from the server's Server-Sent Events
stream into an ordinary Emacs buffer, instead of embedding the opencode TUI in a
terminal. Editor-tool integration is provided to opencode through the `emacs`
MCP server (wired via `opencode.json`), so the client does not reimplement
editor tools.

It requires the [`plz`](https://github.com/alphapapa/plz.el) package, loaded as
an optional dependency — installing `mcp-emacs` does not pull it in, and client
commands report clearly if it is missing.

One opencode server runs **per project**, each on its own free port
(probing upward from `opencode-client-port`, default 4096).  `opencode-client-serve`
starts the server for the current `default-directory` and registers it, so several
projects can run opencode sessions in parallel without colliding on a fixed
address — switch projects and each keeps its own session list.

Configure `opencode-client-host`, `-port`, and optional `-password`, then:

- `M-x opencode-client-connect` — verify a running server (or
  `opencode-client-serve` to start one).
- `M-x opencode-client-create-session` / `-switch-session` — manage sessions.
  Opening a session loads and renders its prior history before streaming, so
  reconnecting to a persistent server shows the existing conversation.
- In the chat buffer: `C-c C-c` to send a prompt (prefix arg steers a running
  turn), `C-c C-k` to interrupt. Permission and question requests are answered
  from Emacs.

The password may be resolved from a secret store instead of set directly:
leave `opencode-client-password` nil and set `opencode-client-password-command`
to a shell command (for example `pass show private/opencode/server-password`);
its trimmed output is used for HTTP basic auth.

To keep sessions alive across Emacs restarts, run the server independently of
Emacs. On macOS, define an on-demand launchd user agent for `opencode serve`
(loaded at login but not started) and set `opencode-client-launchd-label` to its
label; `opencode-client-serve` then starts it with `launchctl kickstart` so the
server is owned by launchd and outlives Emacs, rather than as a child process.

### Claude runner

`elisp/mcp-emacs-run.el` runs the Claude Code CLI inside Emacs. The CLI is a
full-screen TUI, so it runs in an [`eat`](https://codeberg.org/akib/emacs-eat)
terminal buffer (eat is an optional dependency, loaded only when present). The
runner is project-aware, keeps one primary session per project, and displays
its terminal in an ordinary window placed in a configurable direction
(`mcp-emacs-run-window-direction', default `right') rather than a dedicated
side window, so the window stays splittable and closable. Editor-tool
integration is provided to the CLI through the
`mcp-emacs` MCP server via your own MCP configuration (e.g. `.mcp.json`); the
runner only launches and places the terminal.

Configure `mcp-emacs-run-executable` and `-flags`, then:

- `M-x mcp-emacs-run` — start (or switch to) the runner for the current project.
- `M-x mcp-emacs-run-start` — start the runner hidden (no window, no focus); reveal it later with `-toggle` or `-switch`.
- `M-x mcp-emacs-run-continue` / `-resume` — pick up a prior conversation (`-resume` uses the CLI's own in-terminal picker).
- `M-x mcp-emacs-run-resume-select` — pick a past session from a native Emacs `completing-read` (most recent first, labelled with a relative time and the first real prompt) and resume it with `--resume <id>`. Reads the store under `mcp-emacs-run-resume-projects-root` (default `~/.claude/projects`).
- `M-x mcp-emacs-run-toggle` — show/hide the runner window.
- `M-x mcp-emacs-run-list` / `-switch` / `-kill` — manage sessions.
- `M-x mcp-emacs-run-quit` — gracefully quit a session: sends the CLI quit (Ctrl-C twice), then force-kills the process and removes the buffer if it has not exited within `mcp-emacs-run-quit-timeout` seconds (default 10). Unlike `-kill`, it lets the CLI shut down cleanly first.

Drive a running session from anywhere in Emacs (these require a live session and never launch one):

- `M-x mcp-emacs-run-send-prompt` — send a prompt to the session and submit it.
- `M-x mcp-emacs-run-send-escape` / `-send-newline` — send an interrupt, or a newline without submitting.
- `M-x mcp-emacs-run-send-return` — send a bare carriage return (accept a default / submit).
- `M-x mcp-emacs-run-send-1` / `-send-2` / `-send-3` — answer Claude's numbered menus.
- `M-x mcp-emacs-run-send-shift-tab` — cycle Claude's mode.
- `M-x mcp-emacs-run-send-up` / `-send-down` — arrow keys for history/menu navigation.
- `M-x mcp-emacs-explain-selection-in-current-session` — explain the region (or line at point). When the session buffer is visible in a window, the request is sent to the running TUI as `explain @file:line` (or the selected text for non-file buffers). Otherwise — whether the project has a hidden session or none at all — the explanation is fetched with a one-shot headless CLI call (`claude -p ... --output-format text`) and rendered in the popup output window, so it works without an open session and the answer appears near your code.

#### Popup output window

Formatted AI output is shown in a popup output window: a dedicated buffer per
kind (e.g. `*mcp-emacs:explain*`) rendered read-only with
[`markdown-mode`](https://github.com/jrblevin/markdown-mode)'s `gfm-view-mode`
and native code-block fontification. `markdown-mode` is an optional dependency,
loaded only when present; the popup commands error with an install hint if it
is missing. The window is an ordinary split placed via
`mcp-emacs-run-popup-direction' (default `below', size
`mcp-emacs-run-popup-size') — it does not auto-hide, and you can scroll,
select, and copy from it like any buffer. Re-rendering the same kind reuses its
buffer and window. `mcp-emacs-popup-show' is a reusable primitive other
features can render into.

### IDE integration (native-edit diff review)

`elisp/mcp-emacs-ide.el` makes Emacs act as a Claude Code *IDE* so that Claude
Code's **native** Edit/Write operations are reviewed in an interactive ediff
session before they are written — the same accept/reject flow as `apply_diff`,
but triggered automatically instead of only when the model calls a tool.

This is separate from the HTTP MCP server and is **opt-in and off by default**.
It relies on Claude Code's unofficial, reverse-engineered IDE protocol
(WebSocket, verified against Claude Code 2.1.212), so it can break across Claude
Code releases.

How it works: Emacs runs a WebSocket server and launches Claude Code with
`CLAUDE_CODE_SSE_PORT` and `ENABLE_IDE_INTEGRATION=true` in its environment, so
the CLI connects back and calls Emacs's `openDiff` before each edit. Because the
connection is driven by those launch-time environment variables, **only Claude
Code sessions started by the runner get diff review** — a Claude Code you start
by hand in a plain terminal will not.

To enable:

```elisp
(setq mcp-emacs-ide-enabled t)          ; allow the IDE surface to start
(setq mcp-emacs-run-ide-integration t)  ; make the runner launch Claude against it
```

Requires the [`websocket`](https://github.com/ahyatt/emacs-websocket) package
(loaded lazily; the surface errors with an install hint if it is missing). The
runner starts the IDE server automatically on the next launch and manages its
`~/.claude/ide/<port>.lock` discovery file; you can also drive it directly with
`M-x mcp-emacs-ide-start` / `mcp-emacs-ide-stop`.

On the first launch in a project, Claude Code shows a one-time "do you trust
this folder?" prompt; answer it (press Enter / choose *Yes*) so the CLI proceeds
to connect. Reviewing an edit: `C-c C-c` accepts (Claude Code writes the file),
`C-c C-k` or `q` rejects (the file is left unchanged).

The review captures your window configuration before it opens and restores it
when it ends — however you resolve it — so side windows (Treemacs and the like)
come back and your layout is left unchanged. This applies to both `apply_diff`
and the IDE `openDiff` flow, which share the review. By default the diff uses
ediff's plain full-frame layout; set `mcp-emacs-ediff-window-direction` (to
`right` / `left` / `above` / `below`, mirroring `mcp-emacs-run-window-direction`)
to place it in a predictable spot instead.

If you are migrating from `claude-code-ide.el`, disable it for the workspace
first so only one IDE lockfile is published.

### Remote control (Org transcript)

`mcp-emacs-remote.el` (opt-in) lets you drive the interactive Claude session
from ordinary Emacs input and watch its tool activity as a live Org
transcript — without reading the terminal.

- **Prompt input** — `mcp-emacs-remote-prompt` reads a prompt from the
  minibuffer (seeded from the active region when one is set) and sends it to
  the current project's running session; `mcp-emacs-remote-prompt-buffer` sends
  the whole current buffer. Both auto-submit via `mcp-emacs-run-send-prompt`
  and require a live session (they never launch one). Empty or whitespace-only
  input is not sent.
- **Org transcript** — a per-session `*claude: <project>*` Org buffer records
  the session's tool activity: one heading per tool call with its arguments,
  the accept/reject outcome of each `openDiff`, and a run-metadata drawer.
  `getDiagnostics` / `closeAllDiffTabs` are recorded compactly to keep the
  transcript readable.

Enable with `M-x mcp-emacs-remote-enable` (or set `mcp-emacs-remote-enabled`);
the transcript tap on the IDE surface is a no-op while disabled. Recording is
passive — it never changes whether or how a tool call is approved or executed,
and a rendering error cannot stall an edit.

Tool **approval** is not part of this surface: native Edit/Write flow through
the IDE surface's ediff review (above), which is the per-call gate. This is
why the session runs interactively rather than headless — `claude -p` cannot
route per-call approval to Emacs (the `--permission-prompt-tool` flag was
removed in Claude Code 2.1.212). Because the IDE socket carries structured
tool calls but not assistant prose, the transcript records tool activity only
in this version; a full-prose transcript is a tracked follow-up (see #23).

### Resources

| Resource            | Description                                                                               |
|---------------------|-------------------------------------------------------------------------------------------|
| `org-tasks://all`   | All TODO items from org-mode agenda files with status, priority, scheduled/deadline dates |
| `buffer://messages` | Live contents of the Emacs `*Messages*` buffer                                            |
| `buffer://warnings` | Live contents of the Emacs `*Warnings*` buffer                                            |

## Prerequisites

- Emacs 28.1+ with the `web-server` package available
- The `mcp-emacs` and `mcp-emacs-server` features loaded in your session

## Installation

Install the package with your preferred Emacs package manager, pointing it at
the `elisp/` directory of this repository.

`straight.el` / `use-package`:

```elisp
(use-package mcp-emacs-server
  :straight (:host github :repo "gbastkowski/mcp-emacs" :files ("elisp/*.el"))
  :init
  (add-hook 'emacs-startup-hook #'mcp-emacs-server-ensure))
```

Or load it manually from a checkout:

```elisp
(add-to-list 'load-path "/path/to/mcp-emacs/elisp")
(require 'mcp-emacs)
(require 'mcp-emacs-server)
(add-hook 'emacs-startup-hook #'mcp-emacs-server-ensure)
```

## Usage with Claude Code

Start the server in Emacs (the `emacs-startup-hook` above does this
automatically), or on demand:

- Interactively: `M-x mcp-emacs-server-start`
- From a shell against a running Emacs server:

  ```bash
  emacsclient --eval '(mcp-emacs-server-ensure)'   # returns the endpoint URL
  ```

Then point the client at the URL:

```json
{
  "emacs": {
    "type": "http",
    "url": "http://localhost:8765/mcp"
  }
}
```

The listening port is configurable via `M-x customize` (`mcp-emacs-server-port`)
or `(setq mcp-emacs-server-port ...)`.

Lifecycle commands: `mcp-emacs-server-start`, `mcp-emacs-server-ensure`
(idempotent), `mcp-emacs-server-stop`, `mcp-emacs-server-running-p`.

## Architecture

- **`elisp/mcp-emacs.el`**: the `mcp-emacs-*` helper functions that do the work
  (buffer, file, Org, diagnostics).
- **`elisp/mcp-emacs-server.el`**: the MCP server. It uses `web-server` to
  listen on an HTTP port, parses each JSON-RPC request, and dispatches directly
  to the helpers via the tool and resource registries. Optional modules register
  extra tools by pushing descriptors onto `mcp-emacs-server-extra-tools`, so they
  are exposed without editing the core tool list.
- **`elisp/orgspec-*.el`**: the orgspec workflow — `orgspec.el` (marker table),
  `-model` (structs), `-parse` (`org-element` extraction), `-fold` (the delta
  fold), `-commands` (new / status / archive), `-lifecycle` + `-agenda` (the
  TODO lifecycle and in-flight dashboard), and `-mcp` (the typed `orgspec_*`
  tools, registered via the extra-tools hook).
- **HTTP transport**: the MCP client connects to the URL directly; nothing is
  spawned. Requests are dispatched event-driven in the daemon, so the editor is
  never blocked and tools see real session state.

### Flow Diagram

![Emacs Lisp HTTP server flow](docs/elisp-http.png)

The source PlantUML definition lives in `docs/architecture.puml`. Re-render with
`plantuml -tpng docs/architecture.puml`.

## Contributing

Issues and pull requests are welcome.
By contributing you agree that your contributions are licensed under the
project's GPL-3.0-or-later license.

## License

Copyright (C) 2025 Gunnar Bastkowski.

Licensed under the GNU General Public License v3.0 or later
([GPL-3.0-or-later](LICENSE)).
